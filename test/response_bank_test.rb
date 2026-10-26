# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankTest < Minitest::Test
  def setup
    @data = {
      :foo => 'bar',
      :bar => [1, ['a', 'b'], 2, { baz: 'buzz' }],
      'qux' => {
        red: ['blue', 'green'],
        day: true,
        night: nil,
        updated_at: Time.at(1309362467).utc,
        published_on: Time.at(1309320000).utc.to_date,
      },
      :format => Mime::Type.lookup('text/html'),
    }
  end

  # Returns a Hash key as serialized by inspect.
  def k(key)
    { key => 0 }.inspect[1..-3]
  end

  def test_cache_key_for_handles_nested_everything_and_removes_hash_keys_with_nil_values
    expected = %|h4:3:foo3:bar3:bara4:1:1a2:1:a1:b1:2h1:3:baz4:buzz3:quxh5:3:reda2:4:blue5:green3:day4:true5:night0:10:updated_at23:2011-06-29 15:47:47 UTC12:published_on10:2011-06-296:format9:text/html| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(key: @data))
  end

  def test_cache_key_with_no_key_key
    expected = %|{#{k(:foo)}"bar", #{k(:bar)}[1, ["a", "b"], 2, {#{k(:baz)}"buzz"}], #{k("qux")}{#{k(:red)}["blue", "green"], #{k(:day)}true, #{k(:night)}nil, #{k(:updated_at)}2011-06-29 15:47:47 UTC, #{k(:published_on)}Wed, 29 Jun 2011}}| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(@data.tap { |h| h.delete(:format) }))
  end

  def test_cache_key_with_key_and_version
    version = { version: 42 }
    expected = %|h4:3:foo3:bar3:bara4:1:1a2:1:a1:b1:2h1:3:baz4:buzz3:quxh5:3:reda2:4:blue5:green3:day4:true5:night0:10:updated_at23:2011-06-29 15:47:47 UTC12:published_on10:2011-06-296:format9:text/html:h1:7:version2:42| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(key: @data, version: version))
  end

  def test_cache_key_with_version
    key = "/index.html"
    version = 42
    assert_equal('/index.html', ResponseBank.cache_key_for({key: key}))
    assert_equal('/index.html:42', ResponseBank.cache_key_for({key: key, version: version}))
    assert_equal('/index.html:42', ResponseBank.cache_key_for({key: key, version: version, key_schema_version: nil}))
    assert_equal('1:/index.html:42', ResponseBank.cache_key_for({key: key, version: version, key_schema_version: 1}))
  end

  def test_cache_key_for_hash_key_includes_field_names
    assert_equal('h1:1:a1:x', ResponseBank.cache_key_for(key: { a: 'x' }))
    refute_equal(ResponseBank.cache_key_for(key: { a: 'x' }), ResponseBank.cache_key_for(key: { b: 'x' }))
  end

  def test_cache_key_for_hash_key_distinguishes_layouts_with_the_same_joined_values
    keys = [
      { a: 'x,y' },
      { a: 'x', b: 'y' },
      { b: 'x', a: 'y' },
      { a: 'x', b: nil, c: 'y' },
      { a: ['x', 'y'] },
      { a: { x: 'y' } },
      { a: '1:x' },
    ].map { |key| ResponseBank.cache_key_for(key: key) }

    assert_equal(keys.size, keys.uniq.size, keys.inspect)
  end

  def test_cache_key_for_hash_key_preserves_insertion_order
    refute_equal(
      ResponseBank.cache_key_for(key: { a: 'x', b: 'y' }),
      ResponseBank.cache_key_for(key: { b: 'y', a: 'x' })
    )
  end

  def test_cache_key_for_hash_key_with_invalid_utf8_value
    key = ResponseBank.cache_key_for(key: { a: "\xFF".b, b: "caf\u00e9" }, version: 1, encoding: 'br')

    assert_equal("h2:1:a1:\xFF1:b5:caf\xC3\xA9:1:br".b, key.b)
    refute_equal(key, ResponseBank.cache_key_for(key: { a: "\xFE".b, b: "caf\u00e9" }, version: 1, encoding: 'br'))
  end

  def test_cache_key_for_hash_key_with_invalid_utf8_value_and_utf8_version
    key = ResponseBank.cache_key_for(key: { a: "\xFF".b }, version: { v: "caf\u00e9" }, key_schema_version: 1)

    assert_equal("1:h1:1:a1:\xFF:h1:1:v5:caf\xC3\xA9".b, key.b)
  end

  def test_cache_key_for_keeps_utf8_string_keys
    key = ResponseBank.cache_key_for(key: "/caf\u00e9", version: "caf\u00e9")

    assert_equal("/caf\u00e9:caf\u00e9", key)
    assert_equal(Encoding::UTF_8, key.encoding)
  end

  def test_cache_key_for_hash_key_with_nested_values
    key = { path: '/', params: { ids: [1, 2], q: { term: 'a,b' } } }

    assert_equal('h2:4:path1:/6:paramsh2:3:idsa2:1:11:21:qh1:4:term3:a,b', ResponseBank.cache_key_for(key: key))
    assert_equal(ResponseBank.cache_key_for(key: key), ResponseBank.cache_key_for(key: key))
  end

  def test_cache_key_for_array
    assert_equal('["foo", "bar", "baz"]', ResponseBank.cache_key_for(%w[foo bar baz]))
  end

  def test_cache_key_for_int
    assert_equal('1234', ResponseBank.cache_key_for(1234))
  end

  def test_cache_key_for_boolean
    assert_equal('true', ResponseBank.cache_key_for(true))
    assert_equal('false', ResponseBank.cache_key_for(false))
  end

  def test_cache_key_for_symbol
    assert_equal(':asdf', ResponseBank.cache_key_for(:asdf))
  end

  def test_cache_key_for_datetime
    assert_equal(1577836800, ResponseBank.cache_key_for(DateTime.new(2020, 1, 1, 0, 0, 0, '+00:00')))
  end

  def test_cache_key_for_date
    assert_equal("2020-01-01", ResponseBank.cache_key_for(Date.new(2020, 1, 1)))
  end

  def test_compress_retries_once_on_zlib_buferror
    content = 'mycontent'
    compressed_content = Zlib.gzip(content, level: Zlib::BEST_COMPRESSION)
    Zlib.stubs(:gzip).raises(Zlib::BufError).then.returns(compressed_content)

    assert_equal(compressed_content, ResponseBank.compress(content, "gzip"))
  end

  def test_compress_retries_once_on_zlib_buferror_and_raises_if_it_happens_again
    Zlib.stubs(:gzip).raises(Zlib::BufError)

    assert_raises(Zlib::BufError) do
      ResponseBank.compress("mycontent", "gzip")
    end
  end
end
