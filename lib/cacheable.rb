require 'cacheable/middleware'
require 'cacheable/railtie' if defined?(Rails)
require 'cacheable/response_cache_handler'
require 'msgpack'

module Cacheable

  def self.cache_store=(cache_store)
    @cache_store = cache_store
  end

  def self.cache_store
    @cache_store
  end

  def self.log(message)
    @logger.info "[Cacheable] #{message}"
  end

  def self.logger=(logger)
    @logger = logger
  end

  def self.acquire_lock(cache_key)
    raise NotImplementedError, "Override Cacheable.acquire_lock in an initializer."
  end

  def self.write_to_cache(key)
    yield
  end

  def self.compress(content)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.mtime = 1
    gz.write(content)
    io.string
  ensure
    gz.close
  end

  def self.decompress(content)
    Zlib::GzipReader.new(StringIO.new(content)).read
  end

  def self.cache_key_for(data)
    case data
    when Hash
      return data.inspect unless data.key?(:key)
      key = hash_value_str(data[:key])
      return key unless data.key?(:version)
      version = hash_value_str(data[:version])
      return [key, version].join(":")
    when Array
      data.inspect
    when Time, DateTime
      data.to_i
    when Date
      data.to_time.to_i
    when true, false, Fixnum, Symbol, String
      data.inspect
    else
      data.to_s.inspect
    end
  end

  class << self
    private
    def hash_value_str(data)
      if data.is_a?(Hash)
          data.values.join(",")
        else
          data.to_s
      end
    end
  end
end
