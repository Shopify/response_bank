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

  def test_cache_key_for_handles_nested_everything_and_removes_hash_keys_with_nil_values
    expected = %|bar,1,a,b,2,{:baz=>\"buzz\"},{:red=>[\"blue\", \"green\"], :day=>true, :night=>nil, :updated_at=>2011-06-29 15:47:47 UTC, :published_on=>Wed, 29 Jun 2011},text/html| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(key: @data))
  end

  def test_cache_key_with_no_key_key
    expected = %|{:foo=>\"bar\", :bar=>[1, [\"a\", \"b\"], 2, {:baz=>\"buzz\"}], \"qux\"=>{:red=>[\"blue\", \"green\"], :day=>true, :night=>nil, :updated_at=>2011-06-29 15:47:47 UTC, :published_on=>Wed, 29 Jun 2011}}| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(@data.tap { |h| h.delete(:format) }))
  end

  def test_cache_key_with_key_and_version
    version = { version: 42 }
    expected = %|bar,1,a,b,2,{:baz=>\"buzz\"},{:red=>[\"blue\", \"green\"], :day=>true, :night=>nil, :updated_at=>2011-06-29 15:47:47 UTC, :published_on=>Wed, 29 Jun 2011},text/html:42| # rubocop:disable Metrics/LineLength
    assert_equal(expected, ResponseBank.cache_key_for(key: @data, version: version))
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
end
