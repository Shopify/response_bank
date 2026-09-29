# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankTest < Minitest::Test
  def serialized_cache_key(key, version: nil, schema_version: 2, encoding: 'br')
    data = {
      key: key,
      key_schema_version: schema_version,
      encoding: encoding,
    }
    data[:version] = version unless version.nil?
    ResponseBank.cache_key_for(data)
  end

  def test_cache_key_for_distinguishes_delimiter_placement
    first = { a: "a,b", b: "c" }
    second = { a: "a", b: "b,c" }

    refute_equal(serialized_cache_key(first), serialized_cache_key(second))
  end

  def test_cache_key_for_includes_hash_keys
    refute_equal(
      serialized_cache_key({ a: "value" }),
      serialized_cache_key({ b: "value" }),
    )
  end

  def test_cache_key_for_includes_scalar_types
    refute_equal(
      serialized_cache_key({ value: 1 }),
      serialized_cache_key({ value: "1" }),
    )
  end

  def test_cache_key_for_includes_nested_structure
    refute_equal(
      serialized_cache_key({ value: ["a", "b"] }),
      serialized_cache_key({ value: "a,b" }),
    )
  end

  def test_cache_key_for_includes_version
    refute_equal(
      serialized_cache_key("/index.html", version: 1),
      serialized_cache_key("/index.html", version: 2),
    )
  end

  def test_cache_key_for_includes_schema_version
    refute_equal(
      serialized_cache_key("/index.html", schema_version: 1),
      serialized_cache_key("/index.html", schema_version: 2),
    )
  end

  def test_cache_key_for_includes_encoding
    refute_equal(
      serialized_cache_key("/index.html", encoding: "br"),
      serialized_cache_key("/index.html", encoding: "gzip"),
    )
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
