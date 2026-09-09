# frozen_string_literal: true

module ResponseBank
  CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags", "Speculation-Rules"].freeze
  CACHEABLE_STATUSES = [200, 404, 301].freeze

  # Application metadata stored inside the cache entry: set `env[METADATA_ENV_KEY]`
  # (a Hash) before the response is stored; on a server cache hit it holds the Hash
  # stored with the served entry.
  METADATA_ENV_KEY = 'cacheable.metadata'
  # Keeps application metadata apart from ResponseBank's own slots.
  APP_METADATA_KEY = 'app'
end
