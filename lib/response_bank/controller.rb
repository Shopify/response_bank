# frozen_string_literal: true
module ResponseBank
  module Controller
    private

    # Only get? and head? requests should be cached.
    def cacheable_request?
      (request.get? || request.head?) && (request.params[:cache] != 'false')
    end

    # Override this method with additional information that changes to invalidate the cache.
    def cache_version_data
      {}
    end

    def cache_key_data
      { 'request' => { 'env' => request.env.slice('PATH_INFO', 'QUERY_STRING') } }
    end

    def force_refill_cache?
      params[:fill_cache] == "true"
    end

    def skip_browser_cache?
      false
    end

    def serve_unversioned_cacheable_entry?
      false
    end

    # If you're okay with serving pages that are not at the newest version, bump this up
    # to whatever number of seconds you're comfortable with.
    def cache_age_tolerance_in_seconds
      0
    end

    def response_cache(key_data = nil, version_data = nil, &block)
      cacheable_req = cacheable_request?

      unless cache_configured? && cacheable_req
        ResponseBank.log("Uncacheable request. cache_configured='#{!!cache_configured?}'" \
            " cacheable_request='#{cacheable_req}' params_cache='#{request.params[:cache] != 'false'}'")
        response.headers['Cache-Control'] = 'no-cache, no-store' unless cacheable_req
        return yield
      end

      handler = ResponseBank::ResponseCacheHandler.new(
        key_data: key_data || cache_key_data,
        version_data: version_data || cache_version_data,
        env: request.env,
        cache_age_tolerance: cache_age_tolerance_in_seconds,
        serve_unversioned: serve_unversioned_cacheable_entry?,
        force_refill_cache: force_refill_cache?,
        skip_browser_cache: skip_browser_cache?,
        headers: response.headers,
        &block
      )

      status, _headers, body = handler.run!

      return if request.env['cacheable.miss']

      case request.env['cacheable.store']
      when 'server'
        render(status: status, plain: body.first)
      when 'client'
        head(:not_modified)
      end
    end
  end
end
