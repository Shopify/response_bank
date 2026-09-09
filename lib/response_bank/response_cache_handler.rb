# frozen_string_literal: true
require 'digest/md5'
require 'response_bank/brotli_splice_slot'
require 'response_bank/deferred_store'

module ResponseBank
  class ResponseCacheHandler
    CACHE_KEY_SCHEMA_VERSION = 1

    def initialize(
      key_data:,
      version_data:,
      env:,
      cache_age_tolerance:,
      serve_unversioned:,
      headers:,
      force_refill_cache: false,
      skip_browser_cache: false,
      cache_store: ResponseBank.cache_store,
      &block
    )
      @cache_miss_block = block

      @key_data = key_data
      @version_data = version_data
      @env = env
      @cache_age_tolerance = cache_age_tolerance

      @serve_unversioned = serve_unversioned
      @force_refill_cache = force_refill_cache
      @skip_browser_cache = skip_browser_cache
      @cache_store = cache_store
      @headers = headers || {}
      @key_schema_version = @env.key?('cacheable.key_version') ? @env.key['cacheable.key_version'] : CACHE_KEY_SCHEMA_VERSION
    end

    def run!
      @env['cacheable.cache']           = true
      @env['cacheable.key']             = entity_tag_hash
      @env['cacheable.unversioned-key'] = cache_key_hash

      ResponseBank.log(cacheable_info_dump)

      if @force_refill_cache
        refill_cache
      else
        try_to_serve_from_cache
      end
    end

    def entity_tag_hash
      @entity_tag_hash ||= hash(entity_tag)
    end

    def cache_key_hash
      @cache_key_hash ||= hash(cache_key)
    end

    private

    def hash(key)
      "cacheable:" + Digest::MD5.hexdigest(key)
    end

    def entity_tag
      @entity_tag ||= ResponseBank.cache_key_for(key: @key_data, version: @version_data, key_schema_version: @key_schema_version, encoding: @env['response_bank.server_cache_encoding'])
    end

    def cache_key
      @cache_key ||= ResponseBank.cache_key_for(key: @key_data, key_schema_version: @key_schema_version, encoding: @env['response_bank.server_cache_encoding'])
    end

    def cacheable_info_dump
      log_info = [
        "Raw cacheable.key: #{entity_tag}",
        "cacheable.key: #{entity_tag_hash}",
      ]

      if @env['HTTP_IF_NONE_MATCH']
        log_info.push("If-None-Match: #{@env['HTTP_IF_NONE_MATCH']}")
      end

      log_info.join(', ')
    end

    def try_to_serve_from_cache
      response = read_from_cache
      return response if response

      # No cache hit; this request cannot be handled from cache.
      # Yield to the controller and mark for writing into cache.
      refill_cache
    end

    def read_from_cache
      # Etag
      unless @skip_browser_cache
        response = serve_from_browser_cache(entity_tag_hash, @env['HTTP_IF_NONE_MATCH'])
        return response if response
      end

      serve_from_cache(cache_key_hash, @serve_unversioned ? "*" : entity_tag_hash, @cache_age_tolerance)
    rescue => exception
      handle_cache_exception(exception)
      nil
    end

    def serve_from_browser_cache(entity_tag, if_none_match)
      if etag_matches?(entity_tag, if_none_match)
        @env['cacheable.miss']  = false
        @env['cacheable.store'] = 'client'

        @headers.delete('Content-Type')
        @headers.delete('Content-Length')

        ResponseBank.log("Cache hit: client")

        [304, @headers, []]
      end
    end

    def serve_from_cache(cache_key_hash, match_entity_tag = "*", cache_age_tolerance = nil)
      raw = ResponseBank.read_from_backing_cache_store(@env, cache_key_hash, backing_cache_store: @cache_store)

      if raw
        hit = MessagePack.load(raw)

        @env['cacheable.miss']  = false
        @env['cacheable.store'] = 'server'

        status, headers, body, timestamp, compression_level, metadata = hit

        @env['cacheable.compression_level'] = compression_level

        @env['cacheable.locked'] ||= false

        # to preserve the unversioned/versioned logging messages from past releases we split the match_entity_tag test
        if match_entity_tag == "*"
          ResponseBank.log("Cache hit: server (unversioned)")
          # page tolerance only applies for versioned + etag mismatch
        elsif etag_matches?(headers['ETag'], match_entity_tag)
          ResponseBank.log("Cache hit: server")
        else
          # cache miss; check to see if any parallel requests already are regenerating the cache
          if ResponseBank.acquire_lock(match_entity_tag)
            # execute if we can get the lock
            @env['cacheable.locked'] = true
            @env[ResponseBank::DeferredStore::LOCK_OWNED_ENV_KEY] = true
            return
          elsif stale_while_revalidate?(timestamp, cache_age_tolerance)
            # cache is being regenerated, can we avoid piling on and use a stale version in the interim?
            ResponseBank.log("Cache hit: server (recent)")
          else
            ResponseBank.log("Found an unversioned cache entry, but it was too old (#{timestamp})")
            return
          end
        end

        # version check
        # unversioned but tolerance threshold
        # regen
        @headers.merge!(headers)

        if @headers['Content-Encoding']
          if @env['HTTP_ACCEPT_ENCODING'].to_s.include?(@headers['Content-Encoding'])
            if @headers['Content-Encoding'] == 'br'
              body = ResponseBank::BrotliSpliceSlot.replace_compressed_secret(@env, body, metadata)
            end
          else
            ResponseBank.log("uncompressing payload for client as client doesn't require encoding")
            body = ResponseBank.decompress(body, @headers['Content-Encoding'])
            body = ResponseBank::BrotliSpliceSlot.replace_plain_body(@env, body, metadata)
            @headers.delete('Content-Encoding')
          end
        else
          ResponseBank.log("Cache hit, but missing content-encoding in the cache value headers, maybe because of 301 or 404 response or empty body string")
        end

        # After decompression and splicing, so a refill never inherits the rejected
        # entry's metadata; cleared when the served entry has none.
        if metadata&.key?(ResponseBank::APP_METADATA_KEY)
          @env[ResponseBank::METADATA_ENV_KEY] = metadata[ResponseBank::APP_METADATA_KEY]
        else
          @env.delete(ResponseBank::METADATA_ENV_KEY)
        end

        [status, @headers, [body]]

      end
    end

    def etag_matches?(entity_tag, if_none_match)
      # Support for Etag variations including:
      # If-None-Match: abc
      # If-None-Match: "abc"
      # If-None-Match: W/"abc"
      # If-None-Match: "abc", "def"
      # If-None-Match: *
      return false unless entity_tag
      return false unless if_none_match

      return true if if_none_match == "*"

      # strictly speaking an unquoted etag is not valid, yet common
      # to avoid unintended greedy matches in we check for naked entity then includes with quoted entity values
      entity_tag = %{"#{entity_tag}"} unless entity_tag.start_with?('"')

      if_none_match = %{"#{if_none_match}"} unless if_none_match.start_with?('"') || if_none_match.start_with?('W/"')

      if_none_match == entity_tag || if_none_match.include?(entity_tag)
    end

    def stale_while_revalidate?(timestamp, cache_age_tolerance)
      return false if !cache_age_tolerance
      return false if !timestamp

      timestamp >= (Time.now.to_i - cache_age_tolerance)
    end

    def refill_cache
      unless @env['cacheable.locked']
        acquired = ResponseBank.acquire_lock(entity_tag_hash)
        @env[ResponseBank::DeferredStore::LOCK_OWNED_ENV_KEY] = !!acquired
      end
      @env['cacheable.locked'] = true
      @env['cacheable.miss'] = true

      ResponseBank.log("Refilling cache")

      @cache_miss_block.call
    end

    def handle_cache_exception(exception)
      ResponseBank.log("Cache operation failed: #{exception.class} - #{exception.message}")

      if @env['response_bank.on_exception']
        begin
          @env['response_bank.on_exception'].call(exception)
        rescue => handler_exception
          ResponseBank.log("Exception handler failed: #{handler_exception.class} - #{handler_exception.message}")
        end
      end
    end
  end
end
