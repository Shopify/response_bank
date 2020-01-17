# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

ActionController::Base.cache_store = :memory_store

class ResponseCacheHandlerTest < Minitest::Test
  def setup
    @cache_store = stub.tap { |s| s.stubs(read: nil) }
    controller.request.env['HTTP_IF_NONE_MATCH'] = 'deadbeefdeadbeef'
    Cacheable.stubs(:acquire_lock).returns(true)
  end

  def controller
    @controller ||= MockController.new
  end

  def handler
    @handler = Cacheable::ResponseCacheHandler.new(
      key_data: controller.send(:cache_key_data),
      version_data: controller.send(:cache_version_data),
      cache_store: @cache_store,
      env: controller.request.env,
      force_refill_cache: controller.send(:force_refill_cache?),
      serve_unversioned: controller.send(:serve_unversioned_cacheable_entry?),
      cache_age_tolerance: controller.send(:cache_age_tolerance_in_seconds),
      headers: controller.response.headers,
      response: controller.response,
      &proc { [200, {}, 'some text'] }
    )
  end

  def page
    [200, "text/html", Cacheable.compress("<body>hi.</body>"), 1331765506]
  end

  def page_serialized
    MessagePack.dump(page)
  end

  def page_uncompressed
    [200, "text/html", "<body>hi.</body>", 1331765506]
  end

  def test_cache_miss_missing_cache_nil
    controller.response_body = "123"
    my_handler = Cacheable::ResponseCacheHandler.new(
      key_data: controller.send(:cache_key_data),
      version_data: controller.send(:cache_version_data),
      cache_store: @cache_store,
      env: controller.request.env,
      force_refill_cache: controller.send(:force_refill_cache?),
      serve_unversioned: controller.send(:serve_unversioned_cacheable_entry?),
      cache_age_tolerance: controller.send(:cache_age_tolerance_in_seconds),
      headers: controller.response.headers,
      response: controller.response,
      &proc { nil }
    )

    body = my_handler.run!
    assert_equal(['123'], body)
    assert_env(true, nil)
  end

  def test_cache_miss
    _, _, body = handler.run!
    assert_equal('some text', body)
    assert_env(true, nil)
  end

  def test_client_cache_hit
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.versioned_key_hash
    handler.run!
    assert_env(false, 'client')
  end

  def test_server_cache_hit
    controller.request.env['gzip'] = false
    @cache_store.expects(:read).with(handler.versioned_key_hash).returns(page_serialized)
    expect_page_rendered(page_uncompressed)
    handler.run!
    assert_env(false, 'server')
  end

  def test_server_cache_hit_support_gzip
    controller.request.env['gzip'] = true
    @cache_store.expects(:read).with(handler.versioned_key_hash).returns(page_serialized)
    expect_compressed_page_rendered(page)
    handler.run!
    assert_env(false, 'server')
  end

  def test_server_recent_cache_hit
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page_serialized)
    expect_page_rendered(page_uncompressed)
    Cacheable.expects(:acquire_lock).with(handler.versioned_key_hash)
    handler.run!
    assert_env(false, 'server')
  end

  def test_server_recent_cache_acceptable_but_none_found
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    _, _, body = handler.run!
    assert_equal('some text', body)
    assert_env(true, :anything)
  end

  def test_nil_timestamp_in_second_lookup_causes_a_cache_miss
    Cacheable.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(MessagePack.dump(page[0..2]))
    handler.run!
    assert_env(true, :anything)
  end

  def test_recent_cache_available_but_not_acceptable
    Cacheable.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(15)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page_serialized)
    _, _, body = handler.run!
    assert_equal('some text', body)
    assert_env(true, :anything)
  end

  def test_force_refill_cache
    @controller.stubs(force_refill_cache?: true)
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.versioned_key_hash
    @cache_store.stubs(:read).with(handler.versioned_key_hash).returns(page_serialized)

    _, _, body = handler.run!
    assert_env(true, nil)
    assert_equal('some text', body)
  end

  def test_serve_unversioned_cacheable_entry
    controller.request.env['gzip'] = false
    assert(@controller.respond_to?(:serve_unversioned_cacheable_entry?, true))
    @controller.expects(:serve_unversioned_cacheable_entry?).returns(true).times(4)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page_serialized)
    expect_page_rendered(page_uncompressed)
    handler.run!
    assert_env(false, 'server')
  end

  def test_double_render_still_renders
    @controller.stubs(:serve_from_browser_cache)
    @controller.stubs(:serve_from_cache)
    @controller.stubs(force_refill_cache?: false)
    Cacheable.expects(:acquire_lock).once.returns(true)

    handler.run!
    handler.run!
  end

  def assert_env(miss, store)
    vkh  = handler.versioned_key_hash
    uvkh = handler.unversioned_key_hash
    assert_equal(true,  controller.request.env['cacheable.cache'])
    assert_equal(miss,  controller.request.env['cacheable.miss'])

    if store.nil?
      assert_nil(controller.request.env['cacheable.store'])
    elsif store != :anything
      assert_equal(store, controller.request.env['cacheable.store'])
    end

    assert_equal(vkh,   controller.request.env['cacheable.key'])
    assert_equal(uvkh,  controller.request.env['cacheable.unversioned-key'])
  end

  def expect_page_rendered(page)
    _status, content_type, body, _timestamp = page
    Cacheable.expects(:decompress).returns(body).once

    @controller.response.headers.expects(:[]=).with('Content-Type', content_type)
  end

  def expect_compressed_page_rendered(page)
    _status, content_type, _body, _timestamp = page
    Cacheable.expects(:decompress).never

    @controller.response.headers.expects(:[]=).with('Content-Type', content_type)
    @controller.response.headers.expects(:[]=).with('Content-Encoding', "gzip")
  end
end
