# frozen_string_literal: true

require 'response_bank/cache_policy'
require 'response_bank/cache_writer'

module ResponseBank
  class DeferredStore
    ENV_KEY = 'response_bank.deferred_store'
    LOCK_OWNED_ENV_KEY = 'response_bank.fill_lock_owned'
    TERMINAL_STATES = %i[aborted completing consumed].freeze
    PRIVATE_CACHE_DIRECTIVES = %w[private no-store].freeze

    class InvalidContextError < ArgumentError; end
    class StateError < StandardError; end

    class << self
      def create(env, timestamp:)
        validate_context!(env)
        raise InvalidContextError, 'a deferred store is already registered for this request' if env.key?(ENV_KEY)

        new(env, timestamp: timestamp).tap { |store| env[ENV_KEY] = store }
      end

      def from_env(env)
        env[ENV_KEY]
      end

      def arm_from_middleware(env, status:, headers:)
        from_env(env)&.__send__(:arm, status: status, headers: headers)
      end

      private

      def validate_context!(env)
        raise InvalidContextError, 'deferred storage requires a cache miss' unless cache_miss?(env)
        raise InvalidContextError, 'deferred storage requires a GET request' unless env['REQUEST_METHOD'] == 'GET'

        ['cacheable.key', 'cacheable.unversioned-key', 'response_bank.server_cache_encoding'].each do |key|
          raise InvalidContextError, "deferred storage requires #{key}" unless env[key]
        end
        unless env.key?(LOCK_OWNED_ENV_KEY)
          raise InvalidContextError, "deferred storage requires #{LOCK_OWNED_ENV_KEY}"
        end
      end

      def cache_miss?(env)
        env['cacheable.cache'] && env['cacheable.miss']
      end
    end

    def initialize(env, timestamp:)
      @env = env
      @timestamp = timestamp
      @cache_key = env.fetch('cacheable.key')
      @owns_lock = env.fetch(LOCK_OWNED_ENV_KEY) == true
      @mutex = Mutex.new
      @state = :requested
    end

    # `body` and `headers` must describe the complete shared cache representation,
    # not a partial response or bytes personalized for the live client.
    def complete(body:, headers: nil)
      complete_with(headers) do |status, cached_headers, before_write|
        CacheWriter.store(
          @env,
          status: status,
          headers: cached_headers,
          body: body,
          timestamp: @timestamp,
          before_write: before_write,
        )
      end
    end

    # `body` must be a complete Brotli stream that is already safe for shared
    # caching. If present, `slot` describes its neutral replacement slot.
    def complete_spliced(body:, compression_level:, slot: nil, headers: nil)
      complete_with(headers) do |status, cached_headers, before_write|
        CacheWriter.store_spliced(
          @env,
          status: status,
          headers: cached_headers,
          body: body,
          compression_level: compression_level,
          slot: slot,
          timestamp: @timestamp,
          before_write: before_write,
        )
      end
    end

    def abort
      transitioned, release_lock = @mutex.synchronize do
        if TERMINAL_STATES.include?(@state)
          [false, false]
        else
          @state = :aborted
          [true, @owns_lock]
        end
      end

      release_owned_lock if release_lock
      transitioned
    end

    private

    def complete_with(headers)
      status, cached_headers, release_lock = prepare_completion(headers)

      if release_lock
        release_owned_lock
        return false
      end
      return false unless status

      write_started = false
      completed = false
      begin
        yield(status, cached_headers, -> { write_started = true })
        completed = true
      ensure
        @mutex.synchronize { @state = :consumed }
        @env['cacheable.locked'] = false if @owns_lock
        release_owned_lock if @owns_lock && !completed && !write_started
      end
      true
    end

    def arm(status:, headers:)
      @mutex.synchronize do
        if @state != :aborted
          raise StateError, "cannot arm a deferred store in the #{@state} state" unless @state == :requested

          @status = status
          @headers = headers.slice(*ResponseBank::CACHEABLE_HEADERS)
          @eligible = @owns_lock && cache_miss? && status_cacheable?(status)
          @state = :armed
        end
      end

      self
    end

    def prepare_completion(headers)
      @mutex.synchronize do
        raise StateError, 'the deferred store has not been armed by the middleware' if @state == :requested
        return [nil, nil, false] if @state == :aborted
        raise StateError, "cannot complete a deferred store in the #{@state} state" unless @state == :armed

        cached_headers = (headers || @headers).slice(*ResponseBank::CACHEABLE_HEADERS)
        if completion_eligible?(cached_headers)
          @state = :completing
          [@status, cached_headers, false]
        else
          @state = :aborted
          [nil, nil, @owns_lock]
        end
      end
    end

    def completion_eligible?(headers)
      @eligible && cache_miss? && cache_control_allows_storage?(headers)
    end

    def cache_miss?
      @env['cacheable.cache'] && @env['cacheable.miss']
    end

    def status_cacheable?(status)
      ResponseBank::CACHEABLE_STATUSES.include?(status)
    end

    def cache_control_allows_storage?(headers)
      value = headers['Cache-Control']
      return true unless value

      directives = value.split(',').map { |directive| directive.strip.downcase.split('=', 2).first }
      (directives & PRIVATE_CACHE_DIRECTIVES).empty?
    end

    def release_owned_lock
      ResponseBank.release_lock(@cache_key)
    ensure
      @env['cacheable.locked'] = false
    end
  end
end
