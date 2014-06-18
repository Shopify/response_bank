require 'digest/md5'

module Cacheable
  class ResponseCacheHandler
    attr_accessor :key_data, :version_data, :block, :cache_store
    def initialize(controller)
      @controller = controller
      @env = controller.request.env
      @cache_age_tolerance = controller.cache_age_tolerance_in_seconds
      @serve_unversioned = controller.serve_unversioned_cacheable_entry?

      yield self if block_given?
    end

    def run!
      @env['cacheable.cache']           = true
      @env['cacheable.key']             = versioned_key_hash
      @env['cacheable.unversioned-key'] = unversioned_key_hash

      Cacheable.log cacheable_info_dump

      # :cache_return is thrown as soon as we've sent data to the client.
      catch :cache_return do
        try_to_serve_from_cache unless @controller.force_refill_cache?

        # Nothing was thrown; this request cannot be handled from cache.
        # Yield to the controller and mark for writing into cache.
        @env['cacheable.miss'] = true
        run_controller_action!
      end
    end

    def versioned_key_hash
      @versioned_key_hash ||= key_hash(versioned_key)
    end

    def unversioned_key_hash
      @unversioned_key_hash ||= key_hash(unversioned_key)
    end

    private

    def run_controller_action!
      @controller.instance_eval(&@block)
    end

    def key_hash(key)
      "cacheable:#{Digest::MD5.hexdigest(key)}"
    end

    def versioned_key
      @versioned_key ||= Cacheable.cache_key_for(key: key_data, version: version_data)
    end

    def unversioned_key
      @unversioned_key ||= Cacheable.cache_key_for(key: key_data)
    end

    def dump_cache_key_mismatch?
      @env.has_key?('HTTP_X_CACHEABLE_KEY') && @env['HTTP_X_CACHEABLE_KEY'] != versioned_key_hash &&
        @env['HTTP_X_CACHEABLE_SIGNATURE'].present? &&
        @env['HTTP_X_CACHEABLE_SIGNATURE'].split(',').length == versioned_key.split(',').length
    end

    def cacheable_info_dump
      # This should come from nginx
      suggested_key = @env.has_key?('HTTP_X_CACHEABLE_KEY') && @env.has_key?('HTTP_X_CACHEABLE_SIGNATURE') ? "#{@env['HTTP_X_CACHEABLE_KEY']} (#{@env['HTTP_X_CACHEABLE_SIGNATURE'].force_encoding('UTF-8')})" : nil
      str = [
        "Browser gzip: #{@env['gzip']}",
        "Suggested key: #{suggested_key}",
        "Raw cacheable.key: #{versioned_key}",
        "cacheable.key: #{versioned_key_hash}",
        "If-None-Match: #{@env['HTTP_IF_NONE_MATCH']}"
      ].join(", ")
      if dump_cache_key_mismatch?
        Cacheable.log "lua cacheable key mismatch! Dumping HTTP request headers:"
        @controller.request.headers.each { |k,v| Cacheable.log "#{k}: #{v}" if k.to_s.start_with?("HTTP_") }
      end
      str
    end

    def try_to_serve_from_cache

      # Etag
      serve_from_browser_cache(versioned_key_hash)

      # Memcached
      if @serve_unversioned
        serve_from_cache(unversioned_key_hash, nil, "Cache hit: server (unversioned)")
      else
        serve_from_cache(versioned_key_hash)
      end

      # execute if we can get the lock
      execute

      # serve a stale version
      if serving_from_noncurrent_but_recent_version_acceptable?

        serve_from_cache(unversioned_key_hash, @cache_age_tolerance, "Cache hit: server (recent)")

      end
    end

    def execute
      @env['cacheable.locked'] ||= false
      if @env['cacheable.locked'] || Cacheable.acquire_lock(versioned_key_hash)
        @env['cacheable.locked'] = true
        @env['cacheable.miss']  = true
        cache_return!("Refilling cache", &@block)
      end
    end

    def serving_from_noncurrent_but_recent_version_acceptable?
      @cache_age_tolerance > 0
    end

    def serve_from_browser_cache(cache_key_hash)
      if @env["HTTP_IF_NONE_MATCH"] == cache_key_hash
        @env['cacheable.miss']  = false
        @env['cacheable.store'] = 'client'

        cache_return!("Cache hit: client") do
          head :not_modified
        end
      end
    end

    def serve_from_cache(cache_key_hash, cache_age_tolerance=nil, message = "Cache hit: server")
      if raw = @cache_store.read(cache_key_hash)
        hit = MessagePack.load(raw)

        @env['cacheable.miss']  = false
        @env['cacheable.store'] = 'server'

        status, content_type, body, timestamp, location = hit

        if cache_age_tolerance && page_too_old(timestamp, cache_age_tolerance)
          Cacheable.log "Found an unversioned cache entry, but it was too old (#{timestamp})"
        else
          cache_return!(message) do
            response.headers['Content-Type'] = content_type

            response.headers['Location'] = location if location

            if request.env["gzip"]
              response.headers['Content-Encoding'] = "gzip"
            else
              # we have to uncompress because the client doesn't support gzip
              Cacheable.log "uncompressing for client without gzip"
              body = Cacheable.decompress(body)
            end

            render text: body, status: status
          end
        end
      end
    end

    def page_too_old(timestamp, cache_age_tolerance)
      !timestamp || timestamp < (Time.now.to_i - cache_age_tolerance)
    end

    def cache_return!(message, &block)
      Cacheable.log message
      @controller.instance_eval(&block)
      throw :cache_return
    end

  end
end
