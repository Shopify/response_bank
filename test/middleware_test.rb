# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

module EmptyLogger
  def logger
    @logger ||= Logger.new(nil)
  end
end
Rails.singleton_class.prepend(EmptyLogger)

def app(_env)
  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def not_found(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"abcd"'

  body = block_given? ? [yield] : ['Hi']
  [404, { 'Content-Type' => 'text/plain' }, body]
end

def cached_moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"abcd"'
  env['cacheable.store'] = 'server'

  [301, { 'Location' => 'http://shopify.com' }, []]
end

def moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"abcd"'

  [301, { 'Location' => 'http://shopify.com', 'Content-Type' => 'text/plain' }, []]
end

def cacheable_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"abcd"'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def cacheable_app_with_unversioned(env)
  env['cacheable.cache']           = true
  env['cacheable.miss']            = true
  env['cacheable.key']             = '"abcd"'
  env['cacheable.unversioned-key'] = '"abcd-unversioned"'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def already_cached_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"abcd"'
  env['cacheable.store'] = 'server'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def client_hit_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"abcd"'
  env['cacheable.store'] = 'client'

  body = block_given? ? [yield] : ['']
  [304, { 'Content-Type' => 'text/plain' }, body]
end

class MiddlewareTest < Minitest::Test
  def setup
    @original_cache_store = ResponseBank.cache_store
    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(:memory_store)
  end

  def teardown
    ResponseBank.cache_store = @original_cache_store
  end

  def test_cache_miss_and_ignore
    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:app))
    result = ware.call(env)

    assert_nil(result[1]['ETag'])
  end

  def test_cache_miss_and_not_found
    ResponseBank.cache_store.expects(:write).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:not_found))
    result = ware.call(env)

    assert_equal('"abcd"', result[1]['ETag'])
  end

  def test_cache_hit_and_moved
    ResponseBank.cache_store.expects(:write).never

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:cached_moved))
    result = ware.call(env)

    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal('http://shopify.com', result[1]['Location'])
  end

  def test_cache_miss_and_moved
    ResponseBank.cache_store.expects(:write).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(env)

    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal('http://shopify.com', result[1]['Location'])
  end

  def test_cache_miss_and_store
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"abcd"',
        MessagePack.dump([200, 'text/plain', ResponseBank.compress('Hi'), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal('miss', result[1]['X-Cache'])
    assert_nil(env['cacheable.store'])

    # no gzip support here
    assert(!result[1]['Content-Encoding'])
  end

  def test_cache_miss_and_store_with_shortened_cache_expiry
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env['cacheable.versioned-cache-expiry'] = 30.seconds

    ResponseBank.cache_store.expects(:write).with('"abcd"', anything, has_entries(expires_in: 30.seconds))
    ResponseBank.cache_store.expects(:write).with('"abcd-unversioned"', anything, has_entries(expires_in: nil))

    ware = ResponseBank::Middleware.new(method(:cacheable_app_with_unversioned))
    result = ware.call(env)
  end

  def test_cache_miss_and_store_on_moved
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"abcd"',
        MessagePack.dump([301, 'text/plain', ResponseBank.compress(''), 424242, 'http://shopify.com']),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal('miss', result[1]['X-Cache'])
    assert_nil(env['cacheable.store'])

    # no gzip support here
    assert(!result[1]['Content-Encoding'])
  end

  def test_cache_miss_and_store_with_gzip_support
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"abcd"',
        MessagePack.dump([200, 'text/plain', ResponseBank.compress('Hi'), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env['HTTP_ACCEPT_ENCODING'] = 'deflate, gzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal('miss', result[1]['X-Cache'])
    assert_nil(env['cacheable.store'])

    # gzip support!
    assert_equal('gzip', result[1]['Content-Encoding'])
    assert_equal([ResponseBank.compress("Hi")], result[2])
  end

  def test_cache_hit_server
    ResponseBank.cache_store.expects(:write).times(0)

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:already_cached_app))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(!env['cacheable.miss'])
    assert_equal('server', env['cacheable.store'])
    assert_equal('"abcd"', result[1]['ETag'])
  end

  def test_cache_hit_client
    ResponseBank.cache_store.expects(:write).times(0)

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:client_hit_app))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(!env['cacheable.miss'])
    assert_equal('client', env['cacheable.store'])
    assert_equal('"abcd"', result[1]['ETag'])
  end

  def test_ie_ajax
    ware = ResponseBank::Middleware.new(method(:already_cached_app))
    env = Rack::MockRequest.env_for("http://example.com/index.html")

    assert(!ware.send(:ie_ajax_request?, env))

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env["HTTP_USER_AGENT"] = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"

    assert(!ware.send(:ie_ajax_request?, env))

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env["HTTP_USER_AGENT"] = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
    env["HTTP_X_REQUESTED_WITH"] = "XmlHttpRequest"

    assert(ware.send(:ie_ajax_request?, env))

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env["HTTP_USER_AGENT"] = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
    env["HTTP_ACCEPT"] = "application/json"

    assert(ware.send(:ie_ajax_request?, env))
  end

  def test_cache_hit_server_with_ie_ajax
    ResponseBank.cache_store.expects(:write).times(0)

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env["HTTP_USER_AGENT"] = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
    env["HTTP_X_REQUESTED_WITH"] = "XmlHttpRequest"

    ware = ResponseBank::Middleware.new(method(:already_cached_app))
    result = ware.call(env)

    assert(env['cacheable.cache'])
    assert(!env['cacheable.miss'])
    assert_equal('server', env['cacheable.store'])
    assert_equal('"abcd"', result[1]['ETag'])
    assert_equal("-1", result[1]['Expires'])
  end
end
