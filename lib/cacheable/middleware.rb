module Cacheable
  class Middleware

    def initialize(app, cache_store = nil)
      @app = app
      @cache_store = cache_store
    end

    CACHEABLE_STATUSES = [200, 404]

    def call(env)
      env['cacheable.cache'] = false

      status, headers, body = resp = @app.call(env)

      if env['cacheable.cache']

        if CACHEABLE_STATUSES.include?(status) && env['cacheable.miss']

          # Flatten down the result so that it can be stored to memcached.
          if body.is_a?(String)
            body_string = body
          else
            body_string = ""
            body.each { |part| body_string << part }
          end

          # Store result
          body = Snappy.deflate(body_string)
          cache_data = [status, headers['Content-Type'], body, timestamp]
          Cacheable.write_to_cache(env['cacheable.key']) do
            cache.write(env['cacheable.key'], cache_data)
            cache.write(env['cacheable.unversioned-key'], cache_data) if env['cacheable.unversioned-key']
          end
        end

        if CACHEABLE_STATUSES.include?(status) || status == 304
          headers['ETag'] = env['cacheable.key']
          headers['X-Alternate-Cache-Key'] = env['cacheable.unversioned-key']
        end

        # Add X-Cache header
        miss = env['cacheable.miss']
        x_cache = miss ? 'miss' : 'hit'
        x_cache << ", #{env['cacheable.store']}" if !miss
        headers['X-Cache'] = x_cache
      end

      resp
    end

    def timestamp
      Time.now.to_i
    end

    def cache
      @cache_store ||= Rails.cache
    end

  end

end
