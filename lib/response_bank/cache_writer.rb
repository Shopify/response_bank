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
        representation_headers = representation_headers(env, headers)
        stored = prepare_body(env, representation_headers, body, content_encoding)
        persist(
          env,
          status: status,
          representation_headers: representation_headers,
          stored: stored,
          timestamp: timestamp,
          content_encoding: content_encoding,
          before_write: before_write,
        )
      end

      def store_spliced(
        env,
        status:,
        headers:,
        body:,
        compression_level:,
        slot: nil,
        timestamp:,
        before_write: nil
      )
        validate_spliced_body!(env, body)
        metadata = slot && BrotliSpliceSlot.metadata_for(**slot)
        env['cacheable.compression_level'] = compression_level
        persist(
          env,
          status: status,
          representation_headers: representation_headers(env, headers),
          stored: Stored.new(body: nil, compressed_body: body, metadata: metadata),
          timestamp: timestamp,
          content_encoding: 'br',
          before_write: before_write,
        )
      end

      private

      def representation_headers(env, headers)
        headers.slice(*ResponseBank::CACHEABLE_HEADERS).tap do |cached_headers|
          cached_headers['ETag'] = %{"#{env.fetch('cacheable.key')}"}
        end
      end

      def persist(env, status:, representation_headers:, stored:, timestamp:, content_encoding:, before_write:)
        generated_at = timestamp.respond_to?(:call) ? timestamp.call : timestamp
        data = cache_data(status, representation_headers, stored, env, generated_at, content_encoding)

        before_write&.call
        ResponseBank.write_to_cache(env.fetch('cacheable.key')) do
          payload = MessagePack.dump(data)
          ResponseBank.write_to_backing_cache_store(
            env,
            env.fetch('cacheable.unversioned-key'),
            payload,
            expires_in: env['cacheable.versioned-cache-expiry'],
          )
        end

        stored
      end

      def validate_spliced_body!(env, body)
        unless body.is_a?(String) && !body.empty?
          raise ArgumentError, 'spliced body must be a non-empty String'
        end
        return if env.fetch('response_bank.server_cache_encoding') == 'br'

        raise ArgumentError, 'spliced bodies require br server cache encoding'
      end

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
        data << stored.metadata if stored.metadata
        data
      end
    end
  end
end
