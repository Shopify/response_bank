require 'digest/md5'

require 'cacheable/middleware'
require 'cacheable/railtie'
require 'cacheable/response_cache_handler'
require 'cacheable/controller'

module Cacheable
  def self.log(message)
    Rails.logger.info "[Cacheable] #{message}"
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
    when Hash, Array
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
end
