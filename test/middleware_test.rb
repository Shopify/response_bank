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
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'not_found_cache_key'

  body = block_given? ? [yield] : ['Hi']
  [404, { 'Content-Type' => 'text/plain' }, body]
end

def cached_moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cached_moved_cache_key'
  env['cacheable.store'] = 'server'

  [301, { 'Location' => 'http://shopify.com' }, []]
end

def moved(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'moved_cache_key'

  [301, { 'Location' => 'http://shopify.com', 'Content-Type' => 'text/plain' }, []]
end

def cached_spec_rules(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cached_moved_cache_key'
  env['cacheable.store'] = 'server'

  [200, { 'Speculation-Rules' => '"https://shopify.com/specrules.json"' }, []]
end

def spec_rules(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'moved_cache_key'

  [200, { 'Speculation-Rules' => '"https://shopify.com/specrules.json"' }, []]
end

def cacheable_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cacheable_app_cache_key'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def cacheable_app_with_long_response(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cacheable_app_cache_key'

  body = block_given? ? [yield] : ['a' * 100]
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def cacheable_html_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cacheable_html_app_cache_key'

  [200, { 'Content-Type' => 'text/html' }, ['<html><head></head><body>Hi</body></html>']]
end

def cacheable_app_limit_headers(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'cacheable_app_limit_headers_cache_key'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain', 'Extra-Headers' => 'not-cached', 'Cache-Tags' => 'tag1, tag2'}, body]
end

def cacheable_app_with_unversioned(env)
  env['cacheable.cache']           = true
  env['cacheable.miss']            = true
  env['cacheable.key']             = 'etag_value'
  env['cacheable.unversioned-key'] = 'cacheable_app_with_unversioned_cache_key'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def already_cached_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = 'already_cached_app_cache_key'
  env['cacheable.store'] = 'server'

  body = block_given? ? [yield] : ['Hi']
  [200, { 'Content-Type' => 'text/plain' }, body]
end

def prepare_deferred_cache_miss(env)
  env['cacheable.cache'] = true
  env['cacheable.miss'] = true
  env['cacheable.locked'] = true
  env[ResponseBank::DeferredStore::LOCK_OWNED_ENV_KEY] = true
  env['cacheable.key'] = 'etag_value'
  env['cacheable.unversioned-key'] = 'deferred_store_app_cache_key'
end

def deferred_store_app(env)
  prepare_deferred_cache_miss(env)
  env['test.deferred_store'] = ResponseBank.defer_store(env, timestamp: 424242)

  [200, { 'Content-Type' => 'text/plain', 'rack.hijack' => proc {} }, []]
end

def client_hit_app(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = 'etag_value'
  env['cacheable.unversioned-key'] = '"client_hit_app_cache_key"'
  env['cacheable.store'] = 'client'

  body = block_given? ? [yield] : ['']
  [304, { 'Content-Type' => 'text/plain' }, body]
end

# An injector that addresses the slot by byte offset/length (like the README example
# and the real storefront injector), so it can splice the replacement into the
# *uncompressed* body served on the miss -> plain-body branch. The string-substitution
# HtmlMetadataInjector in test_helper only matches once the Brotli body is decompressed.
class OffsetHtmlMetadataInjector
  include ResponseBank::BrotliSpliceInjector

  CONTEXT_SUFFIX = "\r\n"

  def initialize(placeholder:, replacement:)
    @placeholder = placeholder
    @replacement = replacement
  end

  def prepare_response_bank_brotli_splice(body, _headers)
    tag = %(<meta name="shopify-y" content="#{@placeholder}#{CONTEXT_SUFFIX}">)
    html = body.sub('</head>', "#{tag}</head>")
    offset = html.b.index(@placeholder)

    {
      body: html,
      slots: [
        {
          name: 'shopify_y',
          offset: offset,
          length: @placeholder.bytesize + CONTEXT_SUFFIX.bytesize,
        },
      ],
    }
  end

  def response_bank_brotli_splice_replacement(slot)
    @replacement if @replacement.bytesize == slot.fetch('replacement_length')
  end

  def replace_response_bank_brotli_splice_placeholders(body, slots)
    slots.reduce(body) do |current, slot|
      replacement = response_bank_brotli_splice_replacement(slot)
      next current unless replacement

      offset = slot.fetch('html_placeholder_offset')
      length = slot.fetch('html_placeholder_length')
      suffix = slot.fetch('context_suffix', CONTEXT_SUFFIX)
      current.byteslice(0, offset) + replacement + suffix + current.byteslice(offset + length, current.bytesize)
    end
  end
end

class DeferredLifecycleApp
  attr_reader :deferred_store, :render_count

  def initialize
    @render_count = 0
  end

  def call(env)
    handler = ResponseBank::ResponseCacheHandler.new(
      key_data: { path: '/deferred' },
      version_data: { version: 1 },
      env: env,
      cache_age_tolerance: 0,
      serve_unversioned: false,
      headers: {},
    ) do
      @render_count += 1
      @deferred_store = ResponseBank.defer_store(env, timestamp: 424242)
      [
        200,
        {
          'Content-Type' => 'text/html',
          'Cache-Control' => 'no-cache, no-store',
          'rack.hijack' => proc {},
        },
        [],
      ]
    end

    handler.run!
  end
end

class MiddlewareTest < Minitest::Test
  def setup
    @original_cache_store = ResponseBank.cache_store
    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(:memory_store)

    @env = Rack::MockRequest.env_for("http://example.com/index.html")
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, gzip, br'
  end

  def teardown
    ResponseBank.cache_store = @original_cache_store
  end

  def test_cache_miss_and_ignore
    ware = ResponseBank::Middleware.new(method(:app))
    result = ware.call(@env)
    headers = result[1]

    assert_nil(headers['ETag'])
  end

  def test_cache_miss_and_not_found
    ResponseBank.cache_store.expects(:write).once

    ware = ResponseBank::Middleware.new(method(:not_found))
    result = ware.call(@env)

    headers = result[1]
    assert_equal('"etag_value"', headers['ETag'])
  end

  def test_cache_hit_and_moved
    ResponseBank.cache_store.expects(:write).never

    ware = ResponseBank::Middleware.new(method(:cached_moved))
    result = ware.call(@env)
    headers = result[1]

    assert_equal('"etag_value"',headers['ETag'])
    assert_equal('http://shopify.com', headers['Location'])
  end

  def test_cache_miss_and_moved
    ResponseBank.cache_store.expects(:write).once

    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(@env)
    headers = result[1]

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('http://shopify.com', headers['Location'])
    assert(!headers['Content-Encoding'])
  end

  def test_cache_hit_and_specrules
    ResponseBank.cache_store.expects(:write).never

    ware = ResponseBank::Middleware.new(method(:cached_spec_rules))
    result = ware.call(@env)
    headers = result[1]

    assert_equal('"https://shopify.com/specrules.json"', headers['Speculation-Rules'])
  end

  def test_cache_miss_and_specrules
    ResponseBank.cache_store.expects(:write).once

    ware = ResponseBank::Middleware.new(method(:spec_rules))
    result = ware.call(@env)
    headers = result[1]

    assert_equal('"https://shopify.com/specrules.json"', headers['Speculation-Rules'])
  end

  def test_cache_miss_and_store_limited_headers
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_limit_headers_cache_key',
        MessagePack.dump(
          [
            200,
            {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br', 'Cache-Tags' => 'tag1, tag2'},
            ResponseBank.compress('Hi', 'br'),
            424242,
            7
          ]
        ),
        raw: true,
        expires_in: nil,
    ).once
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, pkzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app_limit_headers))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(@env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_and_store
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_cache_key',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' }, ResponseBank.compress('Hi', 'br'), 424242, 7]),
        raw: true,
        expires_in: nil,
    ).once
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, pkzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(@env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_stores_application_metadata_set_by_the_app
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    app = lambda do |env|
      env[ResponseBank::METADATA_ENV_KEY] = { 'variant' => 'b' }
      cacheable_app(env)
    end

    ware = ResponseBank::Middleware.new(app)
    status, headers, body = ware.call(@env)

    payload = MessagePack.load(ResponseBank.cache_store.read('cacheable_app_cache_key', raw: true))
    assert_equal(200, status)
    assert_equal('br', headers['Content-Encoding'])
    assert_equal('Hi', Brotli.inflate(body.first))
    assert_equal([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br'}, ResponseBank.compress('Hi', 'br'), 424242, 7], payload[0..4])
    assert_equal({ 'app' => { 'variant' => 'b' } }, payload[5])
  end

  def test_cache_writer_does_not_use_the_write_hook_return_value
    ResponseBank.stubs(:write_to_cache).yields.returns(nil)

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    status, headers, body = ware.call(@env)

    assert_equal(200, status)
    assert_equal('br', headers['Content-Encoding'])
    assert_equal('Hi', Brotli.inflate(body.first))
  end

  def test_cache_miss_and_store_with_custom_brotli_compression_level_block
    ResponseBank.compression_level = ->(env, headers) { 1 }
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_cache_key',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' }, Brotli.deflate("a" * 100, mode: :text, quality: 1), 424242, 1]),
        raw: true,
        expires_in: nil,
    ).once
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, pkzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app_with_long_response))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])
    assert(@env['cacheable.compression_time'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_equal(1, @env['cacheable.compression_level'])
    assert_nil(@env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  ensure
    ResponseBank.compression_level = nil
  end

  def test_cache_miss_and_store_with_custom_brotli_compression_level
    ResponseBank.compression_level = 1
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_cache_key',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' }, Brotli.deflate("a" * 100, mode: :text, quality: 1), 424242, 1]),
        raw: true,
        expires_in: nil,
    ).once
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, pkzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app_with_long_response))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])
    assert(@env['cacheable.compression_time'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_equal(1, @env['cacheable.compression_level'])
    assert_nil(@env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  ensure
    ResponseBank.compression_level = nil
  end

  def test_cache_miss_and_store_with_shortened_cache_expiry
    @env['cacheable.versioned-cache-expiry'] = 30.seconds

    ResponseBank.cache_store.expects(:write).with('cacheable_app_with_unversioned_cache_key', anything, has_entries(expires_in: 30.seconds))

    ware = ResponseBank::Middleware.new(method(:cacheable_app_with_unversioned))
    result = ware.call(@env)

    headers = result[1]
    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
  end

  def test_cache_miss_and_store_on_moved
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'moved_cache_key',
        MessagePack.dump([ 301, {'Location' => 'http://shopify.com', 'Content-Type' => 'text/plain', 'ETag' => '"etag_value"'}, nil, 424242, nil]),
        raw: true,
        expires_in: nil,
    ).once
    ware = ResponseBank::Middleware.new(method(:moved))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(@env['cacheable.store'])

    # no gzip support here
    assert(!headers['Content-Encoding'])
  end

  def test_cache_miss_and_store_with_gzip_support
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_cache_key',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'gzip'}, ResponseBank.compress('Hi', 'gzip'), 424242, 9]),
        raw: true,
        expires_in: nil,
    ).once

    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, gzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(@env['cacheable.store'])

    # gzip support
    assert_equal('gzip', headers['Content-Encoding'])
    assert_equal([ResponseBank.compress('Hi', 'gzip')], result[2])
  end

  def test_cache_miss_and_store_with_br_support
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_app_cache_key',
        MessagePack.dump([200, {'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' }, ResponseBank.compress('Hi', 'br'), 424242, 7]),
        raw: true,
        expires_in: nil,
    ).once

    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, br, gzip'

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(@env['cacheable.miss'])

    assert_equal('"etag_value"', headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_nil(@env['cacheable.store'])

    # gzip support!
    assert_equal('br', headers['Content-Encoding'])
    assert_equal([ResponseBank.compress("Hi", 'br')], result[2])
  end

  def test_cache_miss_uses_brotli_splice_when_injector_returns_slot
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    injector = HtmlMetadataInjector.new(
      placeholder: '00000000-0000-0000-0000-000000000000',
      replacement: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    )

    ware = ResponseBank::Middleware.new(method(:cacheable_html_app), ->(_env) { injector })
    result = ware.call(@env)
    headers = result[1]

    captured_payload = MessagePack.load(ResponseBank.cache_store.read('cacheable_html_app_cache_key', raw: true))
    status, cached_headers, cached_body, timestamp, compression_level, metadata = captured_payload
    slot = metadata.fetch('brotli_splice').fetch('slots').first

    assert_equal(200, status)
    assert_equal({'Content-Type' => 'text/html', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br'}, cached_headers)
    assert_equal(424242, timestamp)
    assert_equal(7, compression_level)
    assert_equal('shopify_y', slot['name'])
    assert_equal(36, slot['replacement_length'])
    assert_equal(38, slot['html_placeholder_length'])
    assert_equal('br', headers['Content-Encoding'])
    assert_equal('miss', headers['X-Cache'])

    decoded_cached_body = Brotli.inflate(cached_body)
    assert_includes(decoded_cached_body, '00000000-0000-0000-0000-000000000000')
    refute_includes(decoded_cached_body, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')

    decoded_served_body = Brotli.inflate(result[2].first)
    assert_includes(decoded_served_body, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
  end

  def test_cache_miss_with_injector_serves_spliced_plain_body_to_client_without_br
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    @env['HTTP_ACCEPT_ENCODING'] = 'deflate, pkzip' # accepts neither br nor gzip

    injector = OffsetHtmlMetadataInjector.new(
      placeholder: '00000000-0000-0000-0000-000000000000',
      replacement: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    )

    ware = ResponseBank::Middleware.new(method(:cacheable_html_app), ->(_env) { injector })
    result = ware.call(@env)
    headers = result[1]
    served_body = result[2].first

    # The server still Brotli-encodes for its cache -- check_encoding defaults to 'br'
    # even though this client accepts neither br nor gzip -- and stores the neutral
    # placeholder plus the slot metadata.
    captured_payload = MessagePack.load(ResponseBank.cache_store.read('cacheable_html_app_cache_key', raw: true))
    _status, cached_headers, cached_body, _timestamp, _compression_level, metadata = captured_payload
    assert_equal('br', cached_headers['Content-Encoding'])
    assert(metadata, 'expected brotli_splice metadata to be cached')
    assert_includes(Brotli.inflate(cached_body), '00000000-0000-0000-0000-000000000000')

    # Because the client cannot accept br, the middleware takes the
    # `replace_plain_body(...) if metadata` branch (reachable -- not dead code): it
    # serves an uncompressed body with the per-request value spliced in and drops
    # Content-Encoding.
    assert_nil(headers['Content-Encoding'])
    assert_equal('miss', headers['X-Cache'])
    assert_includes(served_body, '<body>Hi</body>')
    assert_includes(served_body, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
    refute_includes(served_body, '00000000-0000-0000-0000-000000000000')
  end

  def test_configured_brotli_splice_injector_is_installed_before_app_call
    injector = HtmlMetadataInjector.new(
      placeholder: '00000000-0000-0000-0000-000000000000',
      replacement: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    )
    app = lambda do |env|
      assert_same(injector, env.fetch(ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY))
      cacheable_html_app(env)
    end

    ware = ResponseBank::Middleware.new(app, ->(_env) { injector })

    ware.call(@env)
  end

  def test_cache_miss_falls_back_to_standard_brotli_when_no_injector
    ResponseBank::Middleware.any_instance.stubs(timestamp: 424242)
    ResponseBank.cache_store.expects(:write).with(
      'cacheable_html_app_cache_key',
      MessagePack.dump([200, {'Content-Type' => 'text/html', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br'}, ResponseBank.compress('<html><head></head><body>Hi</body></html>', 'br'), 424242, 7]),
      raw: true,
      expires_in: nil,
    ).once

    ware = ResponseBank::Middleware.new(method(:cacheable_html_app))
    result = ware.call(@env)

    assert_equal('br', result[1]['Content-Encoding'])
    assert_equal([ResponseBank.compress('<html><head></head><body>Hi</body></html>', 'br')], result[2])
  end

  def test_cache_hit_server
    ResponseBank.cache_store.expects(:write).times(0)

    ware = ResponseBank::Middleware.new(method(:already_cached_app))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(!@env['cacheable.miss'])
    assert_equal('server', @env['cacheable.store'])
    assert_equal('"etag_value"', headers['ETag'])
  end

  def test_cache_hit_client
    ResponseBank.cache_store.expects(:write).times(0)

    ware = ResponseBank::Middleware.new(method(:client_hit_app))
    result = ware.call(@env)
    headers = result[1]

    assert(@env['cacheable.cache'])
    assert(!@env['cacheable.miss'])
    assert_equal('client', @env['cacheable.store'])
    assert_equal('"etag_value"', headers['ETag'])
  end

  def test_exception_during_compression_does_not_fail_request
    ResponseBank.expects(:compress).raises(StandardError.new("Compression failed"))
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes("Failed to write to cache")).once

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)

    # Should still return 200 OK with uncompressed body and no Content-Encoding
    assert_equal(200, result[0])
    assert_nil(result[1]['Content-Encoding'])
    assert_equal('Hi', result[2].join)
  end

  def test_exception_during_serialization_does_not_fail_request
    ResponseBank.expects(:compress).returns("compressed")
    MessagePack.expects(:dump).raises(StandardError.new("Serialization failed"))
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes("Failed to write to cache")).once

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)

    # Should still return 200 OK with uncompressed body and no Content-Encoding
    assert_equal(200, result[0])
    assert_nil(result[1]['Content-Encoding'])
    assert_equal('Hi', result[2].join)
  end

  def test_exception_during_cache_write_does_not_fail_request
    ResponseBank.cache_store.expects(:write).raises(StandardError.new("Cache store is down"))
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes("Failed to write to cache")).once

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)

    # Should still return 200 OK
    assert_equal(200, result[0])
    assert_equal('Hi', result[2].join)
  end

  def test_custom_exception_handler_called_on_middleware_failure
    exception_handled = false
    exception_message = nil

    @env['response_bank.on_exception'] = ->(e) {
      exception_handled = true
      exception_message = e.message
    }

    ResponseBank.expects(:compress).raises(StandardError.new("Compression failed"))
    ResponseBank.stubs(:log)

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)

    assert(exception_handled, "Custom exception handler should have been called")
    assert_equal("Compression failed", exception_message)
    assert_equal(200, result[0])
  end

  def test_exception_in_middleware_custom_handler_is_caught
    @env['response_bank.on_exception'] = ->(e) { raise "Handler itself failed" }

    ResponseBank.expects(:compress).raises(StandardError.new("Compression failed"))
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes("Exception handler failed")).once

    ware = ResponseBank::Middleware.new(method(:cacheable_app))
    result = ware.call(@env)

    # Should still return 200 OK even if exception handler fails
    assert_equal(200, result[0])
    assert_equal('Hi', result[2].join)
  end

  def test_cache_miss_arms_a_deferred_store_without_emitting_an_etag
    ResponseBank.cache_store.expects(:write).never

    ware = ResponseBank::Middleware.new(method(:deferred_store_app))
    status, headers, body = ware.call(@env)

    assert_equal(200, status)
    assert_nil(headers['ETag'])
    assert_equal('miss', headers['X-Cache'])
    assert_equal([], body)
    assert_nil(headers['Content-Encoding'])
    assert_nil(@env['cacheable.compression_level'])
  end

  def test_middleware_tolerates_a_deferred_store_aborted_before_arming
    app = lambda do |env|
      prepare_deferred_cache_miss(env)
      store = ResponseBank.defer_store(env)
      store.abort
      [200, { 'Content-Type' => 'text/plain' }, ['fallback']]
    end
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    status, headers, body = ResponseBank::Middleware.new(app).call(@env)

    assert_equal(200, status)
    assert_nil(headers['ETag'])
    assert_equal(['fallback'], body)
  end

  def test_middleware_aborts_a_deferred_store_when_the_app_raises
    app = lambda do |env|
      prepare_deferred_cache_miss(env)
      ResponseBank.defer_store(env)
      raise StandardError, 'render failed'
    end
    ResponseBank.expects(:release_lock).with('etag_value').once

    error = assert_raises(StandardError) do
      ResponseBank::Middleware.new(app).call(@env)
    end

    assert_equal('render failed', error.message)
  end

  def test_deferred_store_writes_copied_headers_with_etag_and_captured_timestamp
    ware = ResponseBank::Middleware.new(method(:deferred_store_app))
    _status, live_headers, = ware.call(@env)
    cached_headers = { 'Content-Type' => 'text/plain' }

    stored = @env.fetch('test.deferred_store').complete(headers: cached_headers, body: 'Hi')

    assert(stored)
    assert_equal({ 'Content-Type' => 'text/plain' }, cached_headers)
    assert_nil(live_headers['ETag'])
    payload = MessagePack.load(ResponseBank.cache_store.read('deferred_store_app_cache_key', raw: true))
    status, headers, body, timestamp, compression_level = payload
    assert_equal(200, status)
    assert_equal(
      { 'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' },
      headers,
    )
    assert_equal('Hi', Brotli.inflate(body))
    assert_equal(424242, timestamp)
    assert_equal(7, compression_level)
  end

  def test_deferred_miss_completion_is_served_by_following_cache_hits
    ResponseBank.stubs(:acquire_lock).returns(true)
    app = DeferredLifecycleApp.new
    injector = lambda do |env|
      OffsetHtmlMetadataInjector.new(
        placeholder: '00000000-0000-0000-0000-000000000000',
        replacement: env.fetch('HTTP_SHOPIFY_Y'),
      )
    end
    ware = ResponseBank::Middleware.new(app, injector)
    first_env = request_env(encoding: 'br', shopify_y: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')

    first_status, first_headers, = ware.call(first_env)

    assert_equal(200, first_status)
    assert_nil(first_headers['ETag'])
    assert_equal('no-cache, no-store', first_headers['Cache-Control'])
    assert_equal('miss', first_headers['X-Cache'])
    assert(
      app.deferred_store.complete(
        headers: { 'Content-Type' => 'text/html' },
        body: '<html><head></head><body>Hi</body></html>',
      ),
    )

    br_status, br_headers, br_body = ware.call(
      request_env(encoding: 'br', shopify_y: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
    )
    assert_equal(200, br_status)
    assert_equal('hit, server', br_headers['X-Cache'])
    assert_equal('br', br_headers['Content-Encoding'])
    assert_includes(Brotli.inflate(br_body.first), 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
    refute_includes(Brotli.inflate(br_body.first), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')

    plain_status, plain_headers, plain_body = ware.call(
      request_env(encoding: nil, shopify_y: 'cccccccc-cccc-cccc-cccc-cccccccccccc'),
    )
    assert_equal(200, plain_status)
    assert_equal('hit, server', plain_headers['X-Cache'])
    assert_nil(plain_headers['Content-Encoding'])
    assert_includes(plain_body.first, 'cccccccc-cccc-cccc-cccc-cccccccccccc')

    etag = plain_headers.fetch('ETag')
    conditional_env = request_env(encoding: nil, shopify_y: 'dddddddd-dddd-dddd-dddd-dddddddddddd')
    conditional_env['HTTP_IF_NONE_MATCH'] = etag
    conditional_status, conditional_headers, conditional_body = ware.call(conditional_env)
    assert_equal(304, conditional_status)
    assert_equal(etag, conditional_headers['ETag'])
    assert_equal('hit, client', conditional_headers['X-Cache'])
    assert_equal([], conditional_body)
    assert_equal(1, app.render_count)
  end

  private

  def request_env(encoding:, shopify_y:)
    Rack::MockRequest.env_for('http://example.com/deferred').tap do |env|
      env['HTTP_ACCEPT_ENCODING'] = encoding if encoding
      env['HTTP_SHOPIFY_Y'] = shopify_y
    end
  end
end
