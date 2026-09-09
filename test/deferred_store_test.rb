# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankDeferredStoreTest < Minitest::Test
  def setup
    @original_cache_store = ResponseBank.cache_store
    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(:memory_store)
    @env = Rack::MockRequest.env_for("http://example.com/index.html")
    @env['response_bank.server_cache_encoding'] = 'br'
    @env['cacheable.cache'] = true
    @env['cacheable.miss'] = true
    @env['cacheable.locked'] = true
    @env[ResponseBank::DeferredStore::LOCK_OWNED_ENV_KEY] = true
    @env['cacheable.key'] = 'etag_value'
    @env['cacheable.unversioned-key'] = 'store_cache_key'
  end

  def teardown
    ResponseBank.cache_store = @original_cache_store
  end

  def test_defer_store_requires_an_initialized_cache_miss
    @env.delete('cacheable.key')

    error = assert_raises(ResponseBank::DeferredStore::InvalidContextError) do
      ResponseBank.defer_store(@env)
    end

    assert_includes(error.message, 'cacheable.key')
  end

  def test_defer_store_rejects_non_get_requests
    %w[HEAD POST].each do |method|
      @env['REQUEST_METHOD'] = method

      assert_raises(ResponseBank::DeferredStore::InvalidContextError) do
        ResponseBank.defer_store(@env)
      end
    end
  end

  def test_complete_requires_the_middleware_to_arm_the_store
    store = ResponseBank.defer_store(@env)

    assert_raises(ResponseBank::DeferredStore::StateError) do
      store.complete(headers: {}, body: 'Hi')
    end
  end

  def test_complete_is_one_shot_and_abort_after_completion_is_a_no_op
    store = ResponseBank.defer_store(@env, timestamp: 424242)
    ResponseBank::DeferredStore.arm_from_middleware(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
    )
    ResponseBank.expects(:release_lock).never

    assert(store.complete(body: 'Hi'))
    refute(store.abort)
    assert_raises(ResponseBank::DeferredStore::StateError) do
      store.complete(body: 'Hi again')
    end
  end

  def test_complete_stores_application_metadata_set_during_rendering
    store = ResponseBank.defer_store(@env, timestamp: 424242)
    ResponseBank::DeferredStore.arm_from_middleware(
      @env,
      status: 200,
      headers: { 'Content-Type' => 'text/plain' },
    )
    @env[ResponseBank::METADATA_ENV_KEY] = { 'rollout_exposures' => { 'flag' => 'page_viewed' } }

    assert(store.complete(body: 'Hi'))

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal({ 'app' => { 'rollout_exposures' => { 'flag' => 'page_viewed' } } }, payload[5])
  end

  def test_abort_releases_an_owned_lock_once
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    assert(store.abort)
    refute(store.abort)
    refute(store.complete(headers: {}, body: 'Hi'))
    assert_equal(false, @env['cacheable.locked'])
  end

  def test_complete_releases_the_lock_when_compression_fails_before_the_write_hook
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    ResponseBank.stubs(:compress).raises(StandardError, 'compression failed')
    ResponseBank.expects(:write_to_cache).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    assert_raises(StandardError) do
      store.complete(headers: {}, body: 'Hi')
    end
    refute(store.abort)
  end

  def test_complete_aborts_when_rendering_disables_caching
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    @env['cacheable.cache'] = false
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    refute(store.complete(headers: {}, body: 'Hi'))
    refute(store.abort)
  end

  def test_complete_rejects_private_cache_control_from_armed_headers
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(
      @env,
      status: 200,
      headers: { 'Cache-Control' => 'private="Set-Cookie"' },
    )
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    refute(store.complete(body: 'Hi'))
  end

  def test_complete_rejects_no_store_in_final_cached_headers
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).with('etag_value').once

    refute(store.complete(headers: { 'Cache-Control' => 'public, no-store' }, body: 'Hi'))
  end

  def test_write_hook_owns_cleanup_after_a_write_attempt_fails
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    ResponseBank.stubs(:write_to_cache).raises(StandardError, 'write failed')
    ResponseBank.expects(:release_lock).never

    assert_raises(StandardError) do
      store.complete(headers: {}, body: 'Hi')
    end
    refute(store.abort)
  end

  def test_complete_does_not_store_or_release_without_the_fill_lock
    @env['cacheable.locked'] = false
    @env[ResponseBank::DeferredStore::LOCK_OWNED_ENV_KEY] = false
    store = ResponseBank.defer_store(@env)
    ResponseBank::DeferredStore.arm_from_middleware(@env, status: 200, headers: {})
    ResponseBank.cache_store.expects(:write).never
    ResponseBank.expects(:release_lock).never

    refute(store.complete(headers: {}, body: 'Hi'))
  end
end
