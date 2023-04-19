# frozen_string_literal: true

module ResponseBank
  class Middleware
    # Limit the cached headers
    # TODO: Make this lowercase/case-insentitive as per rfc2616 §4.2
    CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags"].freeze

    REQUESTED_WITH = "HTTP_X_REQUESTED_WITH"
    ACCEPT = "HTTP_ACCEPT"
    USER_AGENT = "HTTP_USER_AGENT"

    def initialize(app)
      @app = app
    end

    def call(env)
      env['cacheable.cache'] = false
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
          if body_string && body_string != ""
            headers['Content-Encoding'] = content_encoding
            body_compressed = ResponseBank.compress(body_string, content_encoding)
          end

          cached_headers = headers.slice(*CACHEABLE_HEADERS)
          # Store result
          cache_data = [status, cached_headers, body_compressed, timestamp]

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
              body = [body_compressed]
            else
              # Remove content-encoding header for response with compressed content
              headers.delete('Content-Encoding')
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

    def timestamp
      Time.now.to_i
    end

  end
end
