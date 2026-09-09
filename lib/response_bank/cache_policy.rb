# frozen_string_literal: true

module ResponseBank
  CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags", "Speculation-Rules"].freeze
  CACHEABLE_STATUSES = [200, 404, 301].freeze

  # Application metadata travels inside the cache entry, next to the body it
  # describes, so it can never outlive or lag behind that body. Before a
  # response is stored, the application may set `env[METADATA_ENV_KEY]` to a
  # Hash. On a server cache hit the handler sets the same key to the Hash that
  # was stored with the entry actually being served, stale or not.
  METADATA_ENV_KEY = 'cacheable.metadata'
  # Application metadata is nested under this key in the entry's metadata Hash,
  # apart from ResponseBank's own slots (for example `brotli_splice`).
  APP_METADATA_KEY = 'app'
end
