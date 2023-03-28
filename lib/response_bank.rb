# frozen_string_literal: true
require 'response_bank/middleware'
require 'response_bank/railtie' if defined?(Rails)
require 'response_bank/response_cache_handler'
require 'msgpack'

module ResponseBank
  class << self
    attr_accessor :cache_store
    attr_writer :logger

    def log(message)
      @logger.info("[ResponseBank] #{message}")
    end

    def acquire_lock(_cache_key)
      raise NotImplementedError, "Override ResponseBank.acquire_lock in an initializer."
    end

    def write_to_cache(_key)
      yield
    end

    def write_to_backing_cache_store(_env, key, payload, expires_in: nil)
      cache_store.write(key, payload, raw: true, expires_in: expires_in)
    end

    def read_from_backing_cache_store(_env, cache_key, backing_cache_store: cache_store)
      backing_cache_store.read(cache_key, raw: true)
    end

    def compress(content)
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(content)
      io.string
    ensure
      gz.close
    end

    def decompress(content)
      Zlib::GzipReader.new(StringIO.new(content)).read
    end

    def cache_key_for(data)
      case data
      when Hash
        return data.inspect unless data.key?(:key)

        key = hash_value_str(data[:key])

        key = %{#{data[:key_schema_version]}:#{key}} if data[:key_schema_version]

        key = %{#{key}:#{hash_value_str(data[:version])}} if data[:version]

        key
      when Array
        data.inspect
      when Time, DateTime
        data.to_i
      when Date
        data.to_s # Date#to_i does not support timezones, using iso8601 instead
      when true, false, Integer, Symbol, String
        data.inspect
      else
        data.to_s.inspect
      end
    end

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
