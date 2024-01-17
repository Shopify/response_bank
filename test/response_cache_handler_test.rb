# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

ActionController::Base.cache_store = :memory_store

class ResponseCacheHandlerTest < Minitest::Test
  def setup
    @cache_store = stub.tap { |s| s.stubs(read: nil) }
    controller.request.env['HTTP_IF_NONE_MATCH'] = '"should-not-match"'
    controller.request.env['response_bank.server_cache_encoding'] = 'br'
    ResponseBank.stubs(:acquire_lock).returns(true)
  end

  def controller
    @controller ||= MockController.new
  end

  def handler
    @handler ||= ResponseBank::ResponseCacheHandler.new(
      key_data: controller.send(:cache_key_data),
      version_data: controller.send(:cache_version_data),
      cache_store: @cache_store,
      env: controller.request.env,
      force_refill_cache: controller.send(:force_refill_cache?),
      skip_browser_cache: controller.send(:skip_browser_cache?),
      serve_unversioned: controller.send(:serve_unversioned_cacheable_entry?),
      cache_age_tolerance: controller.send(:cache_age_tolerance_in_seconds),
      headers: controller.response.headers,
      &proc { [200, {}, 'dynamic output'] }
    )
  end

  def page(cache_hit = true, compression="br")
    etag = cache_hit ? handler.entity_tag_hash : "not-cached"
    [200, {"Content-Type" => "text/html", "ETag" => %{"#{etag}"}, "Content-Encoding" => compression}, ResponseBank.compress("<body>cached output</body>", compression), 1331765506]
  end

  def page_cache_entry(cache_hit = true, compression="br")
    MessagePack.dump(page(cache_hit, compression))
  end

  def page_uncompressed(cache_hit = true)
    etag = cache_hit ? handler.entity_tag_hash : "not-cached"
    [200, {"Content-Type" => "text/html", "ETag" => %{"#{etag}"}}, "<body>cached output</body>", 1331765506]
  end

  def test_cache_miss_block_is_only_called_once_if_it_return_nil
    called = 0
    my_handler = ResponseBank::ResponseCacheHandler.new(
      key_data: controller.send(:cache_key_data),
      version_data: controller.send(:cache_version_data),
      cache_store: @cache_store,
      env: controller.request.env,
      force_refill_cache: controller.send(:force_refill_cache?),
      serve_unversioned: controller.send(:serve_unversioned_cacheable_entry?),
      cache_age_tolerance: controller.send(:cache_age_tolerance_in_seconds),
      headers: controller.response.headers,
      &->() do
        called += 1
        nil
      end
    )

    my_handler.run!
    assert_equal(1, called)
    assert_cache_miss(true, nil)
  end

  def test_cache_miss
    _, _, body = handler.run!
    assert_equal('dynamic output', body)
    assert_cache_miss(true, nil)
  end

  def test_client_cache_hit
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.entity_tag_hash
    handler.run!
    assert_cache_miss(false, 'client')
  end

  def test_client_cache_hit_quoted
    controller.request.env['HTTP_IF_NONE_MATCH'] = "\"#{handler.entity_tag_hash}\""
    handler.run!
    assert_cache_miss(false, 'client')
  end

  def test_client_cache_hit_multi
    controller.request.env['HTTP_IF_NONE_MATCH'] = "foo, \"#{handler.entity_tag_hash}\", bar"
    handler.run!
    assert_cache_miss(false, 'client')
  end

  def test_client_cache_hit_weak
    controller.request.env['HTTP_IF_NONE_MATCH'] = "W/\"#{handler.entity_tag_hash}\""
    handler.run!
    assert_cache_miss(false, 'client')
  end

  def test_client_cache_hit_wildcard
    controller.request.env['HTTP_IF_NONE_MATCH'] = "*"
    handler.run!
    assert_cache_miss(false, 'client')
  end

  def test_client_cache_miss_partial
    controller.request.env['HTTP_IF_NONE_MATCH'] = "aaa#{handler.entity_tag_hash}zzz"
    handler.run!
    assert_cache_miss(true, nil)
  end

  def test_server_cache_hit_return_uncompressed
    controller.request.env['response_bank.server_cache_encoding'] = 'br'
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(true, 'br'))
    page_decompressed = [200, {"Content-Type" => "text/html", "ETag" => handler.entity_tag_hash, "Content-Encoding" => 'br'}, "<body>cached output</body>", 1331765506]
    expect_page_rendered(page_decompressed, nil)
    assert_cache_miss(false, 'server')
  end

  def test_server_cache_hit_but_empty_body
    controller.request.env['response_bank.server_cache_encoding'] = 'br'
    empty_page = [200, {"Content-Type" => "text/html", "ETag" => handler.entity_tag_hash, "Content-Encoding" => nil}, "", 1331765506]
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(MessagePack.dump(empty_page))
    controller.request.env['HTTP_ACCEPT_ENCODING'] = 'br'

    _status, _headers, _body, _timestamp = empty_page
    ResponseBank.expects(:decompress).never

    status, headers, _body = handler.run!

    assert_equal(_status, status)
    assert_equal(_headers['Content-Type'], headers["Content-Type"])
    assert_nil(headers["Content-Encoding"])
    assert_cache_miss(false, 'server')
  end

  def test_server_cache_hit_support_gzip
    controller.request.env['response_bank.server_cache_encoding'] = 'gzip'
    cache_entry = [200, {"Content-Type" => "text/html", "ETag" => handler.entity_tag_hash, "Content-Encoding" => 'br'}, "<body>cached output</body>", 1331765506]
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(MessagePack.dump(cache_entry))
    controller.request.env['HTTP_ACCEPT_ENCODING'] = 'gzip'

    _status, _headers, _body, _timestamp = cache_entry

    ResponseBank.expects(:decompress).returns(_body).once

    status, headers, _body = handler.run!

    assert_equal(_status, status)
    assert_equal(_headers['Content-Type'], headers["Content-Type"])
    assert_nil(headers["Content-Encoding"])
    assert_cache_miss(false, 'server')
  end

  def test_server_recent_cache_hit
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(false, 'br'))
    ResponseBank.expects(:acquire_lock).with(handler.entity_tag_hash)
    expect_page_rendered(page(false), 'br')

    assert_cache_miss(false, 'server')
  end

  def test_server_recent_cache_acceptable_but_none_found
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    _, _, body = handler.run!
    assert_equal('dynamic output', body)
    assert_cache_miss(true, :anything)
  end

  def test_nil_timestamp_in_second_lookup_causes_a_cache_miss
    ResponseBank.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    cache_page = page(false)
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(MessagePack.dump(cache_page[0..2]))
    handler.run!

    assert_cache_miss(true, :anything)
  end

  def test_server_recent_cache_miss
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(false))

    ResponseBank.expects(:acquire_lock).with(handler.entity_tag_hash).returns(true)
    handler.run!

    assert_cache_miss(true, 'server')
  end

  def test_recent_cache_available_but_not_acceptable
    ResponseBank.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(15)
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(false))
    _, _, body = handler.run!
    assert_equal('dynamic output', body)
    assert_cache_miss(true, :anything)
  end

  def test_force_refill_cache
    @controller.stubs(force_refill_cache?: true)
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.entity_tag_hash
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).never

    _, _, body = handler.run!
    assert_cache_miss(true, nil)
    assert_equal('dynamic output', body)
  end

  def test_skip_browser_cache_never_loads_from_browser
    @controller.stubs(skip_browser_cache?: true)
    @controller.expects(:serve_from_browser_cache).never
    controller.request.env['response_bank.server_cache_encoding'] = 'br'
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.entity_tag_hash
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(true, 'br'))

    page_decompressed = [200, {"Content-Type" => "text/html", "ETag" => handler.entity_tag_hash, "Content-Encoding" => 'br'}, "<body>cached output</body>", 1331765506]
    expect_page_rendered(page_decompressed, nil)
    assert_cache_miss(false, 'server')
  end

  def test_serve_unversioned_cacheable_entry
    assert(@controller.respond_to?(:serve_unversioned_cacheable_entry?, true))
    @controller.expects(:serve_unversioned_cacheable_entry?).returns(true).times(1)
    @cache_store.expects(:read).with(handler.cache_key_hash, raw: true).returns(page_cache_entry(false))
    expect_page_rendered(page, 'br')
    assert_cache_miss(false, 'server')
  end

  def test_double_render_still_renders
    @controller.stubs(:serve_from_browser_cache)
    @controller.stubs(:serve_from_cache)
    @controller.stubs(force_refill_cache?: false)
    ResponseBank.expects(:acquire_lock).once.returns(true)

    handler.run!
    handler.run!
  end

  def assert_cache_miss(miss, store)
    etag  = handler.entity_tag_hash
    unversioned_cache_key = handler.cache_key_hash
    assert_equal(true, controller.request.env['cacheable.cache'])
    assert_equal(miss, controller.request.env['cacheable.miss'])

    if (miss)
      assert_equal(true, controller.request.env['cacheable.locked'])
    end

    if store.nil?
      assert_nil(controller.request.env['cacheable.store'])
    elsif store != :anything
      assert_equal(store, controller.request.env['cacheable.store'])
    end

    assert_equal(etag, controller.request.env['cacheable.key'])
    assert_equal(unversioned_cache_key, controller.request.env['cacheable.unversioned-key'])
  end

  def expect_page_rendered(cache_entry, content_encoding = 'br')
    controller.request.env['HTTP_ACCEPT_ENCODING'] = content_encoding

    _status, _headers, _body, _timestamp = cache_entry

    if !_body.nil? &&
      !_body.empty? &&
      !_headers['Content-Encoding'].nil? &&
      !content_encoding.to_s.include?(_headers['Content-Encoding'])
      ResponseBank.expects(:decompress).returns(_body).once
    else
      ResponseBank.expects(:decompress).never
    end

    status, headers, body = handler.run!

    assert_equal(_status, status)
    assert_equal(_headers['Content-Type'], headers["Content-Type"])
    assert_equal(content_encoding, headers["Content-Encoding"]) if content_encoding

    body
  end
end
