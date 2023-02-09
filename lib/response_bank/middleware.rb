# frozen_string_literal: true
require 'useragent'

module ResponseBank
  class Middleware
    REQUESTED_WITH = "HTTP_X_REQUESTED_WITH"
    ACCEPT = "HTTP_ACCEPT"
    USER_AGENT = "HTTP_USER_AGENT"

    def initialize(app)
      @app = app
    end

    def call(env)
      env['cacheable.cache'] = false
      gzip = env['gzip'] = env['HTTP_ACCEPT_ENCODING'].to_s.include?("gzip")

      status, headers, body = @app.call(env)

      if env['cacheable.cache']
        if [200, 404, 301, 304].include?(status)
          headers['ETag'] = "\"#{env['cacheable.key']}\""
          headers['X-Alternate-Cache-Key'] = env['cacheable.unversioned-key']

          if ie_ajax_request?(env)
            headers["Expires"] = "-1"
          end
        end

        if [200, 404, 301].include?(status) && env['cacheable.miss']
          # Flatten down the result so that it can be stored to memcached.
          if body.is_a?(String)
            body_string = body
          else
            body_string = +""
            body.each { |part| body_string << part }
          end

          body_gz = ResponseBank.compress(body_string)

          # Store result
          cache_data = [status, headers['Content-Type'], body_gz, timestamp]
          cache_data << headers['Location'] if status == 301

          ResponseBank.write_to_cache(env['cacheable.key']) do
            payload = MessagePack.dump(cache_data)
            ResponseBank.write_to_backing_cache_store(
              env,
              env['cacheable.key'],
              payload,
              expires_in: env['cacheable.versioned-cache-expiry'],
            )

            if env['cacheable.unversioned-key']
              ResponseBank.write_to_backing_cache_store(env, env['cacheable.unversioned-key'], payload)
            end
          end

          # since we had to generate the gz version above already we may
          # as well serve it if the client wants it
          if gzip
            headers['Content-Encoding'] = "gzip"
            body = [body_gz]
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

    def ie_ajax_request?(env)
      return false unless !env[USER_AGENT].nil? && !env[USER_AGENT].empty?

      if env[REQUESTED_WITH] == "XmlHttpRequest" || env[ACCEPT] == "application/json"
        UserAgent.parse(env["HTTP_USER_AGENT"]).is_a?(UserAgent::Browsers::InternetExplorer)
      else
        false
      end
    end
  end
end
