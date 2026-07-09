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
end
