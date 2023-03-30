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
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"not_found_cache_key"'

  body = block_given? ? [yield] : ['Hi']
  [404, { 'Content-Type' => 'text/plain' }, body]
end

def cached_moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"cached_moved_cache_key"'
  env['cacheable.store'] = 'server'

  [301, { 'Location' => 'http://shopify.com' }, []]
end

def moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"moved_cache_key"'

  [301, { 'Location' => 'http://shopify.com', 'Content-Type' => 'text/plain' }, []]
end

def cacheable_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"cacheable_app_cache_key"'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def cacheable_app_limit_headers(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"cacheable_app_limit_headers_cache_key"'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain', 'Extra-Headers' => 'not-cached', 'Cache-Tags' => 'tag1, tag2'}, body]
end

def cacheable_app_with_unversioned(env)
  env['cacheable.cache']           = true
  env['cacheable.miss']            = true
  env['cacheable.key']             = '"etag_value"'
  env['cacheable.unversioned-key'] = '"cacheable_app_with_unversioned_cache_key"'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def already_cached_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"already_cached_app_cache_key"'
  env['cacheable.store'] = 'server'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def client_hit_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"etag_value"'
  env['cacheable.unversioned-key'] = '"client_hit_app_cache_key"'
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
    headers = result[1]

    assert_nil(headers['ETag'])
  end

  def test_cache_miss_and_not_found
    ResponseBank.cache_store.expects(:write).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:not_found))
    result = ware.call(env)

    headers = result[1]
    assert_equal('"etag_value"', headers['ETag'])
  end

  def test_cache_hit_and_moved
    ResponseBank.cache_store.expects(:write).never

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:cached_moved))
    result = ware.call(env)
    headers = result[1]

    assert_equal('"etag_value"',headers['ETag'])
    assert_equal('http://shopify.com', headers['Location'])
  end

  def test_cache_miss_and_moved
    ResponseBank.cache_store.expects(:write).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(env)
    headers = result[1]

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('http://shopify.com', headers['Location'])
  end

  def test_cache_miss_and_store_limited_headers
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"cacheable_app_limit_headers_cache_key"',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Cache-Tags' => 'tag1, tag2'}, ResponseBank.compress('Hi'), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:cacheable_app_limit_headers))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_and_store
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"cacheable_app_cache_key"',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"' }, ResponseBank.compress('Hi'), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_and_store_with_shortened_cache_expiry
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env['cacheable.versioned-cache-expiry'] = 30.seconds

    ResponseBank.cache_store.expects(:write).with('"cacheable_app_with_unversioned_cache_key"', anything, has_entries(expires_in: 30.seconds))

    ware = ResponseBank::Middleware.new(method(:cacheable_app_with_unversioned))
    result = ware.call(env)

    headers = result[1]
    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
  end

  def test_cache_miss_and_store_on_moved
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"moved_cache_key"',
        MessagePack.dump([301, {'Location' => 'http://shopify.com', 'Content-Type' => 'text/plain', 'ETag' => '"etag_value"'}, ResponseBank.compress(''), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_and_store_with_gzip_support
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      '"cacheable_app_cache_key"',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"' }, ResponseBank.compress('Hi'), 424242]),
        raw: true,
        expires_in: nil,
    ).once

    env = Rack::MockRequest.env_for("http://example.com/index.html")
    env['HTTP_ACCEPT_ENCODING'] = 'deflate, gzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(env['cacheable.store'])

    # gzip support!
    assert_equal('gzip', headers['Content-Encoding'])
    assert_equal([ResponseBank.compress("Hi")], result[2])
  end

  def test_cache_hit_server
    ResponseBank.cache_store.expects(:write).times(0)

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:already_cached_app))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(!env['cacheable.miss'])
    assert_equal('server', env['cacheable.store'])
    assert_equal('"etag_value"', headers['ETag'])
  end

  def test_cache_hit_client
    ResponseBank.cache_store.expects(:write).times(0)

    env = Rack::MockRequest.env_for("http://example.com/index.html")

    ware = ResponseBank::Middleware.new(method(:client_hit_app))
    result = ware.call(env)
    headers = result[1]

    assert(env['cacheable.cache'])
    assert(!env['cacheable.miss'])
    assert_equal('client', env['cacheable.store'])
    assert_equal('"etag_value"', headers['ETag'])
  end
end
