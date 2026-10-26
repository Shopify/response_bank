# frozen_string_literal: true
require 'response_bank/brotli_splice_injector'
require 'response_bank/brotli_splice_slot'
require 'response_bank/cache_policy'
require 'response_bank/cache_writer'
require 'response_bank/deferred_store'
require 'response_bank/middleware'
require 'response_bank/railtie' if defined?(Rails)
require 'response_bank/response_cache_handler'
require 'msgpack'
require 'brotli'
require 'benchmark'

module ResponseBank
  private_constant :CacheWriter

  class << self
    attr_accessor :cache_store
    attr_writer :logger, :compression_level

    DEFAULT_BROTLI_COMPRESSION_LEVEL = 7

    DEFAULT_COMPRESSION_LEVEL = -> (env, _headers) {
      case env['response_bank.server_cache_encoding']
      when 'br'
        DEFAULT_BROTLI_COMPRESSION_LEVEL
      when 'gzip'
        Zlib::BEST_COMPRESSION
      end
    }

    def compression_level_for_request(env, headers)
      if @compression_level
        return @compression_level.respond_to?(:call) ? @compression_level.call(env, headers) : @compression_level
      end

      DEFAULT_COMPRESSION_LEVEL.call(env, headers)
    end

    def log(message)
      @logger.info("[ResponseBank] #{message}")
    end

    def acquire_lock(_cache_key)
      raise NotImplementedError, "Override ResponseBank.acquire_lock in an initializer."
    end

    # Starts a one-shot deferred cache fill for the current ResponseBank miss.
    # Complete it only after the intended shared response was generated and
    # written successfully. Abort failed, disconnected or truncated responses.
    def defer_store(env, timestamp: Time.now.to_i)
      DeferredStore.create(env, timestamp: timestamp)
    end

    # Override when deferred fills must release an application-managed lock.
    def release_lock(_cache_key)
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

    def measure
      Benchmark.realtime do
        yield
      end * 1000 # milliseconds
    end

    def compress(content, encoding = "br", compression_level: nil)
      case encoding
      when 'gzip'
        attempts = 0

        begin
          Zlib.gzip(content, level: compression_level || Zlib::BEST_COMPRESSION)
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
        Brotli.deflate(content, mode: :text, quality: compression_level || DEFAULT_BROTLI_COMPRESSION_LEVEL)
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
        key = append_key_component(String.new(encoding: Encoding::BINARY), data)
        key.force_encoding(Encoding::UTF_8)
        key.valid_encoding? ? key : key.force_encoding(Encoding::BINARY)
      else
        data.to_s
      end
    end

    # Hashes and Arrays are written as a type tag and element count, followed
    # by their elements; Hash entries are written as name then value, in
    # insertion order. Every other value is written as the byte length of its
    # #to_s followed by those bytes, so no value can be read as part of another.
    def append_key_component(buffer, data)
      case data
      when Hash
        buffer << "h" << data.size.to_s << ":"
        data.each do |name, value|
          append_key_component(buffer, name)
          append_key_component(buffer, value)
        end
      when Array
        buffer << "a" << data.size.to_s << ":"
        data.each { |value| append_key_component(buffer, value) }
      else
        value = data.to_s.b
        buffer << value.bytesize.to_s << ":" << value
      end
      buffer
    end
  end
end
