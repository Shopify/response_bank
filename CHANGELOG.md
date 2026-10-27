# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.9.0] - 2026-10-27

### Added
- `prepare_response_bank_brotli_splice` may return several slots. Each gets its
  own metadata entry, and a Brotli cache hit fills them all with one copy of the
  body; a slot whose replacement does not fit keeps its placeholder. The cache
  format and `BrotliSpliceSlot::METADATA_VERSION` are unchanged, so existing
  entries still read correctly ([#127]).

### Changed
- Brotli splicing requires `brotli_splice` 0.3.0 or newer. Apps that use splice
  slots must upgrade it in the same deploy: with an older version installed,
  spliced misses and Brotli hits on spliced entries raise `Gem::LoadError`,
  which ResponseBank does not rescue ([#127]).
- `BrotliSpliceSlot.metadata_for` takes an Array of slot descriptors ([#127]).

### Fixed
- When an injector prepares a body whose slots cannot be encoded, the prepared
  body is cached without slots instead of the response as rendered, so
  per-request values no longer reach the shared cache ([#127]).
- When an injector returns a Hash without `:body`, ResponseBank raises
  `ArgumentError` and caches nothing, instead of caching the response as
  rendered ([#127]).

## [1.8.0] - 2026-10-26

### Changed
- Hash cache keys include field names. Each field name and value is written
  with a length prefix, and nested Hashes and Arrays with their element count,
  so hashes with different fields, or values containing `,`, no longer produce
  the same key. String and other non-Hash keys are unchanged. Entries cached
  under a Hash key get a new key, so they miss once after upgrading ([#128]).

## [1.7.0] - 2026-09-29

### Added
- `env['cacheable.timestamp']` and `env['cacheable.stale']` expose the served
  server-cache entry's generation time and stale-while-revalidate status ([#125]).

## [1.6.0] - 2026-09-17

### Added
- Application metadata stored inside the cache entry: a Hash set in
  `env['cacheable.metadata']` before the response is stored travels with the
  cached body and is exposed under the same key on a server cache hit, fresh or
  stale. Entries without it keep the existing cache format. Constants
  `ResponseBank::METADATA_ENV_KEY` and `ResponseBank::APP_METADATA_KEY` ([#119]).

## [1.5.0] - 2026-09-14

### Added
- `DeferredStore#complete_spliced` for storing complete Brotli bodies without a
  second compression pass. ResponseBank serializes optional splice metadata
  using the existing cache format ([#118]).

## [1.4.0] - 2026-08-11

### Added
- `ResponseBank.defer_store`, which returns a one-shot handle for completing or
  aborting a cache miss after the Rack tuple returns ([#112]).
- `ResponseBank.release_lock`, an optional hook used when an abandoned deferred
  fill must release its lock ([#112]).
- `ResponseBank::CACHEABLE_STATUSES`, the gem's storage policy, with the existing
  middleware constant retained as an alias ([#112]).

### Changed
- Deferred responses do not emit a live ETag. A successful completion adds the
  ETag only to the cached representation ([#112]).
- Cache writes build a separate cached-header hash instead of adding
  `Content-Encoding` to the caller's live headers ([#112]).
- Deferred completion requires logical fill-lock ownership recorded by
  `ResponseCacheHandler` ([#112]).
- A one-element Rack body holding a String is no longer copied before it is
  compressed. An Array subclass keeps the enumeration path, because it may
  override `each` ([#112]).

## [1.3.8] - 2026-07-10

### Added
- Brotli splice cache slot handling: reserve fixed-length slots in a
  Brotli-compressed cached response body and splice per-request values into them
  at serve time, without recompressing the body ([#103]).
- `brotli_splice` as a dependency, powering the splice slot support ([#102]).

Releases prior to 1.3.8 are recorded in the project's git tags and GitHub Releases.

[1.9.0]: https://github.com/Shopify/response_bank/releases/tag/v1.9.0
[1.8.0]: https://github.com/Shopify/response_bank/releases/tag/v1.8.0
[1.7.0]: https://github.com/Shopify/response_bank/releases/tag/v1.7.0
[1.6.0]: https://github.com/Shopify/response_bank/releases/tag/v1.6.0
[1.5.0]: https://github.com/Shopify/response_bank/releases/tag/v1.5.0
[1.4.0]: https://github.com/Shopify/response_bank/releases/tag/v1.4.0
[1.3.8]: https://github.com/Shopify/response_bank/releases/tag/v1.3.8
[#102]: https://github.com/Shopify/response_bank/pull/102
[#103]: https://github.com/Shopify/response_bank/pull/103
[#112]: https://github.com/Shopify/response_bank/pull/112
[#118]: https://github.com/Shopify/response_bank/pull/118
[#119]: https://github.com/Shopify/response_bank/pull/119
[#125]: https://github.com/Shopify/response_bank/pull/125
[#127]: https://github.com/Shopify/response_bank/pull/127
[#128]: https://github.com/Shopify/response_bank/pull/128
