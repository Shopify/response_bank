# frozen_string_literal: true
require 'response_bank/middleware'
require 'response_bank/railtie' if defined?(Rails)
require 'response_bank/response_cache_handler'
require 'msgpack'
require 'brotli'

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

    def compress(content, encoding = "br")
      case encoding
      when 'gzip'
        attempts = 0

        begin
          Zlib.gzip(content, level: Zlib::BEST_COMPRESSION)
        rescue Zlib::BufError
          # We get sporadic Zlib::BufError, so we retry once (https://github.com/ruby/zlib/issues/49)
          attempts += 1

          if attempts <= 1
            retry
          else
            raise
          end
        end
      when 'br'
        Brotli.deflate(content, mode: :text, quality: 7)
      else
        raise ArgumentError, "Unsupported encoding: #{encoding}"
      end
    end

    def decompress(content, encoding = "br")
      case encoding
      when 'gzip'
        Zlib.gunzip(content)
      when 'br'
        Brotli.inflate(content)
      else
        raise ArgumentError, "Unsupported encoding: #{encoding}"
      end
    end

    def cache_key_for(data)
      case data
      when Hash
        return data.inspect unless data.key?(:key)

        key = hash_value_str(data[:key])

        key = %{#{data[:key_schema_version]}:#{key}} if data[:key_schema_version]

        key = %{#{key}:#{hash_value_str(data[:version])}} if data[:version]

        # add the encoding to only the cache key but don't expose this detail in the entity_tag
        key = %{#{key}:#{hash_value_str(data[:encoding])}} if data[:encoding]

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

    def check_encoding(env, default_encoding = 'br')
      if env['HTTP_ACCEPT_ENCODING'].to_s.include?('br')
        'br'
      elsif env['HTTP_ACCEPT_ENCODING'].to_s.include?('gzip')
        'gzip'
      else
        # No encoding requested from client, but we still need to cache the page in server cache
        default_encoding
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
