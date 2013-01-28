module Cacheable
  class Middleware

    def initialize(app, cache_store = nil)
      @app = app
      @cache_store = cache_store
    end

    def call(env)
      env['cacheable.cache'] = false
      gzip = env['gzip'] = env['HTTP_ACCEPT_ENCODING'].to_s.include?("gzip")

      status, headers, body = @app.call(env)

      if env['cacheable.cache']

        if [200, 404, 301, 304].include?(status)
          headers['ETag'] = env['cacheable.key']
          headers['X-Alternate-Cache-Key'] = env['cacheable.unversioned-key']
        end

        if [200, 404, 301].include?(status) && env['cacheable.miss']

          # Flatten down the result so that it can be stored to memcached.
          if body.is_a?(String)
            body_string = body
          else
            body_string = ""
            body.each { |part| body_string << part }
          end

          body_gz = Cacheable.compress(body_string)

          # Store result
          cache_data = [status, headers['Content-Type'], body_gz, timestamp]
          cache_data << headers['Location'] if status == 301

          Cacheable.write_to_cache(env['cacheable.key']) do
            cache.write(env['cacheable.key'], cache_data)
            cache.write(env['cacheable.unversioned-key'], cache_data) if env['cacheable.unversioned-key']
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
        x_cache << ", #{env['cacheable.store']}" if !miss
        headers['X-Cache'] = x_cache
      end

      [status, headers, body]
    end

    def timestamp
      Time.now.to_i
    end

    def cache
      @cache_store ||= Rails.cache
    end

  end

end
