# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankCacheWriterTest < Minitest::Test
  class RewritingBody < Array
    def each
      super { |part| yield("#{part}!") }
    end
  end

  def setup
    @original_cache_store = ResponseBank.cache_store
    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(:memory_store)
    @env = Rack::MockRequest.env_for("http://example.com/index.html")
    @env['response_bank.server_cache_encoding'] = 'br'
    @env['cacheable.key'] = 'etag_value'
    @env['cacheable.unversioned-key'] = 'store_cache_key'
  end

  def teardown
    ResponseBank.cache_store = @original_cache_store
  end

  def test_store_copies_headers_and_adds_cache_representation_headers
    headers = {
      'Content-Type' => 'text/plain',
      'ETag' => 'caller-etag',
      'Content-Encoding' => 'gzip',
    }.freeze

    stored = cache_writer.store(
      @env,
      status: 200,
      headers: headers,
      body: ['Hi'],
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_equal('Hi', stored.body)
    assert_equal(ResponseBank.compress('Hi', 'br'), stored.compressed_body)
    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      [
        200,
        { 'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' },
        ResponseBank.compress('Hi', 'br'),
        424242,
        7,
      ],
      payload,
    )
  end

  def test_store_writes_an_empty_body_without_content_encoding
    headers = { 'Location' => 'http://shopify.com', 'Content-Encoding' => 'gzip' }.freeze

    stored = cache_writer.store(
      @env,
      status: 301,
      headers: headers,
      body: [],
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_nil(stored.compressed_body)
    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      [301, { 'Location' => 'http://shopify.com', 'ETag' => '"etag_value"' }, nil, 424242, nil],
      payload,
    )
  end

  def test_store_does_not_copy_a_single_chunk_body
    chunk = 'Hi'

    stored = cache_writer.store(
      @env,
      status: 200,
      headers: {},
      body: [chunk],
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_same(chunk, stored.body)
  end

  def test_store_enumerates_an_array_subclass
    stored = cache_writer.store(
      @env,
      status: 200,
      headers: {},
      body: RewritingBody.new(['Hi']),
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_equal('Hi!', stored.body)
  end

  def test_store_keeps_only_cacheable_headers
    cache_writer.store(
      @env,
      status: 200,
      headers: {
        'Content-Type' => 'text/plain',
        'Cache-Tags' => 'tag1',
        'Extra-Headers' => 'not-cached',
      },
      body: ['Hi'],
      timestamp: 424242,
      content_encoding: 'br',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      {
        'Content-Type' => 'text/plain',
        'ETag' => '"etag_value"',
        'Content-Encoding' => 'br',
        'Cache-Tags' => 'tag1',
      },
      payload[1],
    )
  end

  def test_store_nests_application_metadata_in_the_entry
    @env[ResponseBank::METADATA_ENV_KEY] = { 'variant' => 'b' }

    cache_writer.store(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
      body: 'Hi',
      timestamp: 424242,
      content_encoding: 'gzip',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(6, payload.length)
    assert_equal({ 'app' => { 'variant' => 'b' } }, payload[5])
  end

  def test_store_ignores_application_metadata_that_cannot_be_serialized
    @env[ResponseBank::METADATA_ENV_KEY] = { 'when' => Object.new }
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes('cacheable.metadata')).once

    cache_writer.store(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
      body: 'Hi',
      timestamp: 424242,
      content_encoding: 'gzip',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(5, payload.length)
  end

  def test_store_keeps_the_entry_shape_without_application_metadata
    cache_writer.store(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
      body: 'Hi',
      timestamp: 424242,
      content_encoding: 'gzip',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(5, payload.length)
  end

  def test_store_merges_application_metadata_with_brotli_splice_metadata
    @env[ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY] = HtmlMetadataInjector.new(
      placeholder: '00000000-0000-0000-0000-000000000000',
      replacement: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    )
    @env[ResponseBank::METADATA_ENV_KEY] = { 'variant' => 'a' }

    cache_writer.store(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/html' },
      body: '<html><head></head><body>Hi</body></html>',
      timestamp: 424242,
      content_encoding: 'br',
    )

    metadata = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))[5]
    assert_equal({ 'variant' => 'a' }, metadata['app'])
    assert_equal('shopify_y', metadata.dig('brotli_splice', 'slots', 0, 'name'))
  end

  def test_store_ignores_application_metadata_that_is_not_a_hash
    @env[ResponseBank::METADATA_ENV_KEY] = 'oops'
    ResponseBank.stubs(:log)
    ResponseBank.expects(:log).with(includes('cacheable.metadata')).once

    cache_writer.store(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
      body: 'Hi',
      timestamp: 424242,
      content_encoding: 'gzip',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(5, payload.length)
  end

  private

  def cache_writer
    ResponseBank.const_get(:CacheWriter, false)
  end
end
