require File.dirname(__FILE__) + "/test_helper"

ActionController::Base.cache_store = :memory_store

module Rails
  def self.cache
  end
  def self.logger
    @logger ||= Logger.new(nil)
  end
end

def app(env)
  body = block_given? ? [yield] : ['Hi']
  [ 200, {'Content-Type' => 'text/plain'}, body ]
end

def not_found(env)
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"abcd"'
  
  body = block_given? ? [yield] : ['Hi']
  [ 404, {'Content-Type' => 'text/plain'}, body ]
end

def cacheable_app(env)  
  env['cacheable.cache'] = true
  env['cacheable.miss']  = true
  env['cacheable.key']   = '"abcd"'
  
  body = block_given? ? [yield] : ['Hi']
  [ 200, {'Content-Type' => 'text/plain'}, body ]
end

def already_cached_app(env)  
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"abcd"'
  env['cacheable.store'] = 'server'
  
  body = block_given? ? [yield] : ['Hi']
  [ 200, {'Content-Type' => 'text/plain'}, body ]
end

def client_hit_app(env)  
  env['cacheable.cache'] = true
  env['cacheable.miss']  = false
  env['cacheable.key']   = '"abcd"'
  env['cacheable.store'] = 'client'
  
  body = block_given? ? [yield] : ['']
  [ 304, {'Content-Type' => 'text/plain'}, body ]
end

class MiddlewareTest < MiniTest::Unit::TestCase
  
  def setup
    @cache_store = ActiveSupport::Cache::MemoryStore.new
  end
    
  def test_cache_miss_and_ignore
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    
    ware = Cacheable::Middleware.new(method(:app), @cache_store)
    result = ware.call(env)

    assert_nil result[1]['Etag']
  end
      
  def test_cache_miss_and_not_found
    Cacheable::Middleware.any_instance.stubs(timestamp: 424242)
    @cache_store.expects(:write).with('"abcd"', [404, 'text/plain', Snappy.deflate('Hi'), 424242]).times(1)
    
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    
    ware = Cacheable::Middleware.new(method(:not_found), @cache_store)
    result = ware.call(env)

    assert env['cacheable.cache']
    assert env['cacheable.miss']
        
    assert_equal '"abcd"', result[1]['ETag']
    assert_equal 'miss', result[1]['X-Cache']
    assert_nil env['cacheable.store']
  end
  
  def test_cache_miss_and_store
    Cacheable::Middleware.any_instance.stubs(timestamp: 424242)
    @cache_store.expects(:write).with('"abcd"', [200, 'text/plain', Snappy.deflate('Hi'), 424242]).times(1)
    
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    
    ware = Cacheable::Middleware.new(method(:cacheable_app), @cache_store)
    result = ware.call(env)

    assert env['cacheable.cache']
    assert env['cacheable.miss']
        
    assert_equal '"abcd"', result[1]['ETag']
    assert_equal 'miss', result[1]['X-Cache']
    assert_nil env['cacheable.store']
  end
  
  def test_cache_hit_server
    @cache_store.expects(:write).times(0)
    
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    
    ware = Cacheable::Middleware.new(method(:already_cached_app), @cache_store)
    result = ware.call(env)

    assert env['cacheable.cache']
    assert !env['cacheable.miss']
    assert_equal 'server', env['cacheable.store']
    assert_equal '"abcd"', result[1]['ETag']
  end
  
  def test_cache_hit_client
    @cache_store.expects(:write).times(0)
    
    env = Rack::MockRequest.env_for("http://example.com/index.html")
    
    ware = Cacheable::Middleware.new(method(:client_hit_app), @cache_store)
    result = ware.call(env)

    assert env['cacheable.cache']
    assert !env['cacheable.miss']
    assert_equal 'client', env['cacheable.store']
    assert_equal '"abcd"', result[1]['ETag']
  end
  
end
