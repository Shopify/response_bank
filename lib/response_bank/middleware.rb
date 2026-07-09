# frozen_string_literal: true
require 'response_bank/brotli_splice_slot'

module ResponseBank
  class Middleware
    # Limit the cached headers
    # TODO: Make this lowercase/case-insentitive as per rfc2616 §4.2
    CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags", "Speculation-Rules"].freeze

    REQUESTED_WITH = "HTTP_X_REQUESTED_WITH"
    ACCEPT = "HTTP_ACCEPT"
    USER_AGENT = "HTTP_USER_AGENT"

    def initialize(app, brotli_splice_injector = nil)
      @app = app
      @brotli_splice_injector = brotli_splice_injector
    end

    def call(env)
      env['cacheable.cache'] = false
      install_brotli_splice_injector(env)

      content_encoding = env['response_bank.server_cache_encoding'] = ResponseBank.check_encoding(env)

      status, headers, body = @app.call(env)

      if env['cacheable.cache']
        if [200, 404, 301, 304].include?(status)
          headers['ETag'] = %{"#{env['cacheable.key']}"}
        end

        if [200, 404, 301].include?(status) && env['cacheable.miss']
          # Flatten down the result so that it can be stored to memcached.
          if body.is_a?(String)
            body_string = body
          else
            body_string = +""
            body.each { |part| body_string << part }
          end

          body_compressed = nil
          metadata = nil
          if body_string && body_string != ""
            headers['Content-Encoding'] = content_encoding
            env["cacheable.compression_level"] = ResponseBank.compression_level_for_request(env, headers)
            time = ResponseBank.measure do
              encoded_body = if content_encoding == 'br'
                ResponseBank::BrotliSpliceSlot.encode_body(
                  env,
                  body_string,
                  headers,
                  compression_level: env["cacheable.compression_level"],
                )
              end

              if encoded_body
                body_string = encoded_body.body
                body_compressed = encoded_body.compressed_body
                metadata = encoded_body.metadata
              else
                body_compressed = ResponseBank.compress(
                  body_string,
                  content_encoding,
                  compression_level: env["cacheable.compression_level"],
                )
              end
            end
            ResponseBank.log("Compression time: #{time}ms")
            env["cacheable.compression_time"] = time
          end

          cached_headers = headers.slice(*CACHEABLE_HEADERS)
          # Store result
          cache_data = [status, cached_headers, body_compressed, timestamp, env["cacheable.compression_level"]]
          cache_data << metadata if metadata

          ResponseBank.write_to_cache(env['cacheable.key']) do
            payload = MessagePack.dump(cache_data)
            ResponseBank.write_to_backing_cache_store(
              env,
              env['cacheable.unversioned-key'],
              payload,
              expires_in: env['cacheable.versioned-cache-expiry'],
            )
          end

          # since we had to generate the compressed version already we may
          # as well serve it if the client wants it
          if body_compressed
            if env['HTTP_ACCEPT_ENCODING'].to_s.include?(content_encoding)
              if content_encoding == 'br'
                body = [ResponseBank::BrotliSpliceSlot.replace_compressed_secret(env, body_compressed, metadata)]
              else
                body = [body_compressed]
              end
            else
              # Remove content-encoding header for response with compressed content
              headers.delete('Content-Encoding')
              body = [ResponseBank::BrotliSpliceSlot.replace_plain_body(env, body_string, metadata)] if metadata
            end
          end
        end

        # Add X-Cache header
        miss = env['cacheable.miss']
        x_cache = miss ? 'miss' : 'hit'
        x_cache += ", #{env['cacheable.store']}" unless miss
        headers['X-Cache'] = x_cache
      end

      [status, headers, body]
    end

    private

    def install_brotli_splice_injector(env)
      return unless @brotli_splice_injector
      return if env.key?(ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY)

      injector = if @brotli_splice_injector.respond_to?(:call)
        @brotli_splice_injector.call(env)
      else
        @brotli_splice_injector
      end

      env[ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY] = injector if injector
    end

    def timestamp
      Time.now.to_i
    end

  end
end
