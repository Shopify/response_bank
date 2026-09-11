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

  def test_store_spliced_accepts_a_cache_safe_brotli_body
    compressed_body = ResponseBank.compress('already compressed', 'br')
    slot = {
      name: 'shopify_y',
      compressed_offset: 1,
      replacement_length: 2,
      html_placeholder_offset: 10,
      html_placeholder_length: 4,
      context_suffix: "\r\n",
    }
    ResponseBank.expects(:compress).never
    ResponseBank.expects(:log).never

    stored = cache_writer.store_spliced(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/html' },
      body: compressed_body,
      compression_level: 5,
      slot: slot,
      timestamp: 424242,
    )

    assert_nil(stored.body)
    assert_equal(compressed_body, stored.compressed_body)
    assert_equal(5, @env['cacheable.compression_level'])
    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      [
        200,
        { 'Content-Type' => 'text/html', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' },
        compressed_body,
        424242,
        5,
        {
          'brotli_splice' => {
            'version' => 1,
            'slots' => [{
              'name' => 'shopify_y',
              'compressed_offset' => 1,
              'replacement_length' => 2,
              'html_placeholder_offset' => 10,
              'html_placeholder_length' => 4,
              'context_suffix' => "\r\n",
            }],
          },
        },
      ],
      payload,
    )
  end

  def test_store_spliced_accepts_a_body_without_a_slot
    compressed_body = ResponseBank.compress('already compressed', 'br')

    cache_writer.store_spliced(
      @env,
      status: 200,
      headers: {},
      body: compressed_body,
      compression_level: 5,
      timestamp: 424242,
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(5, payload.length)
    assert_equal(compressed_body, payload[2])
  end

  def test_store_spliced_rejects_the_wrong_server_cache_encoding
    @env['response_bank.server_cache_encoding'] = 'gzip'

    assert_raises(ArgumentError) do
      cache_writer.store_spliced(
        @env,
        status: 200,
        headers: {},
        body: 'already compressed',
        compression_level: 5,
        timestamp: 424242,
      )
    end
  end

  def test_store_spliced_rejects_missing_bytes
    assert_raises(ArgumentError) do
      cache_writer.store_spliced(
        @env,
        status: 200,
        headers: {},
        body: '',
        compression_level: 5,
        timestamp: 424242,
      )
    end
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

  private

  def cache_writer
    ResponseBank.const_get(:CacheWriter, false)
  end
end
