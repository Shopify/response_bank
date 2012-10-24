require File.dirname(__FILE__) + "/test_helper"

ActionController::Base.cache_store = :memory_store

class ResponseCacheHandlerTest < MiniTest::Unit::TestCase

  def setup
    @cache_store = stub.tap { |s| s.stubs(read: nil)}
    controller.request.env['HTTP_IF_NONE_MATCH'] = 'deadbeefdeadbeef'
    Cacheable.stubs(:acquire_lock).returns(true)
  end

  def controller
    @controller ||= MockController.new
  end

  def handler
    @handler ||= Cacheable::ResponseCacheHandler.new(controller) do |h|
      h.key_data       = controller.cache_key_data
      h.version_data   = controller.cache_version_data
      h.block          = proc { response.body = 'some text' }
      h.cache_store    = @cache_store
    end
  end

  def page
    [200, "text/html", "\x10<<body>hi.</body>", 1331765506]
  end

  def test_cache_miss
    handler.run!
    assert_equal 'some text', controller.response.body
    assert_env(true, nil)
  end

  def test_client_cache_hit
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.versioned_key_hash
    controller.expects(:head).with(:not_modified) 
    handler.run!
    assert_env(false, 'client')
  end

  def test_server_cache_hit
    @cache_store.expects(:read).with(handler.versioned_key_hash).returns(page)
    expect_page_rendered(page)
    handler.run!
    assert_env(false, 'server')
  end

  def test_server_recent_cache_hit
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page)
    expect_page_rendered(page)
    Cacheable.expects(:acquire_lock).with(handler.versioned_key_hash)
    handler.run!
    assert_env(false, 'server')
  end

  def test_server_recent_cache_acceptable_but_none_found
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    handler.run!
    assert_equal 'some text', controller.response.body
    assert_env(true, :anything)
  end

  def test_nil_timestamp_in_second_lookup_causes_a_cache_miss
    Cacheable.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(999999999999)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page[0..2])
    handler.run!
    assert_env(true, :anything)
  end

  def test_recent_cache_available_but_not_acceptable
    Cacheable.stubs(:acquire_lock).returns(false)
    @controller.stubs(:cache_age_tolerance_in_seconds).returns(15)
    @cache_store.expects(:read).with(handler.unversioned_key_hash).returns(page)
    handler.run!
    assert_equal 'some text', controller.response.body
    assert_env(true, :anything)
  end

  def test_force_refill_cache
    controller.request.env['HTTP_IF_NONE_MATCH'] = handler.versioned_key_hash
    @cache_store.stubs(:read).with(handler.versioned_key_hash).returns(page)
    @controller.stubs(force_refill_cache?: true)

    handler.run!
    assert_env(true, nil)
    assert_equal 'some text', controller.response.body
  end

  def assert_env(miss, store)
    vkh  = handler.versioned_key_hash
    uvkh = handler.unversioned_key_hash
    assert_equal true,  controller.request.env['cacheable.cache']
    assert_equal miss,  controller.request.env['cacheable.miss']
    assert_equal store, controller.request.env['cacheable.store'] unless store == :anything
    assert_equal vkh,   controller.request.env['cacheable.key']
    assert_equal uvkh,  controller.request.env['cacheable.unversioned-key']
  end

  def expect_page_rendered(page)
    status, content_type, body, timestamp = page
    body = Snappy.inflate(body)
    @controller.expects(:render).with(text: body, status: status)
    @controller.response.headers.expects(:[]=).with('Content-Type', content_type)
  end

end
