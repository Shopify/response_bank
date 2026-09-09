# frozen_string_literal: true

require 'response_bank/brotli_splice_slot'
require 'response_bank/cache_policy'
require 'msgpack'

module ResponseBank
  class CacheWriter
    Stored = Struct.new(:body, :compressed_body, :metadata, keyword_init: true)

    class << self
      def flatten(body)
        if body.is_a?(String)
          body
        elsif body.instance_of?(Array) && body.size == 1 && body[0].is_a?(String)
          body[0]
        else
          result = +''
          body.each { |part| result << part }
          result
        end
      end

      def store(
        env,
        status:,
        headers:,
        body:,
        timestamp:,
        content_encoding: env.fetch('response_bank.server_cache_encoding'),
        before_write: nil
      )
        cache_key = env.fetch('cacheable.key')
        unversioned_key = env.fetch('cacheable.unversioned-key')
        representation_headers = headers.slice(*ResponseBank::CACHEABLE_HEADERS)
        representation_headers['ETag'] = %{"#{cache_key}"}
        stored = prepare_body(env, representation_headers, body, content_encoding)
        generated_at = timestamp.respond_to?(:call) ? timestamp.call : timestamp
        data = cache_data(status, representation_headers, stored, env, generated_at, content_encoding)

        before_write&.call
        ResponseBank.write_to_cache(cache_key) do
          payload = MessagePack.dump(data)
          ResponseBank.write_to_backing_cache_store(
            env,
            unversioned_key,
            payload,
            expires_in: env['cacheable.versioned-cache-expiry'],
          )
        end

        stored
      end

      private

      def prepare_body(env, headers, body, content_encoding)
        body = flatten(body)
        return Stored.new(body: body) if body.empty?

        representation_headers = headers.merge('Content-Encoding' => content_encoding)
        compression_level = ResponseBank.compression_level_for_request(env, representation_headers)
        env['cacheable.compression_level'] = compression_level
        body_compressed = nil
        metadata = nil
        time = ResponseBank.measure do
          encoded_body = encode_spliced_body(
            env,
            body,
            representation_headers,
            content_encoding,
            compression_level,
          )

          if encoded_body
            body = encoded_body.body
            body_compressed = encoded_body.compressed_body
            metadata = encoded_body.metadata
          else
            body_compressed = ResponseBank.compress(
              body,
              content_encoding,
              compression_level: compression_level,
            )
          end
        end
        ResponseBank.log("Compression time: #{time}ms")
        env['cacheable.compression_time'] = time

        Stored.new(body: body, compressed_body: body_compressed, metadata: metadata)
      end

      def encode_spliced_body(env, body, headers, content_encoding, compression_level)
        return unless content_encoding == 'br'

        ResponseBank::BrotliSpliceSlot.encode_body(
          env,
          body,
          headers,
          compression_level: compression_level,
        )
      end

      def cache_data(status, representation_headers, stored, env, timestamp, content_encoding)
        if stored.compressed_body
          representation_headers['Content-Encoding'] = content_encoding
        else
          representation_headers.delete('Content-Encoding')
        end
        cached_headers = representation_headers.slice(*ResponseBank::CACHEABLE_HEADERS)
        data = [status, cached_headers, stored.compressed_body, timestamp, env['cacheable.compression_level']]
        metadata = entry_metadata(env, stored.metadata)
        data << metadata if metadata
        data
      end

      # A non-Hash value is logged and skipped rather than failing the write.
      def entry_metadata(env, metadata)
        app_metadata = env[ResponseBank::METADATA_ENV_KEY]
        return metadata if app_metadata.nil?
        unless app_metadata.is_a?(Hash)
          ResponseBank.log("Ignoring #{ResponseBank::METADATA_ENV_KEY}: expected a Hash, got #{app_metadata.class}")
          return metadata
        end

        (metadata || {}).merge(ResponseBank::APP_METADATA_KEY => app_metadata)
      end
    end
  end
end
