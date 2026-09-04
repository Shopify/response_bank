# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - Unreleased

### Added
- `DeferredStore#complete_spliced` for storing complete Brotli bodies without a
  second compression pass. ResponseBank serializes optional splice metadata
  using the existing cache format.

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

[1.5.0]: https://github.com/Shopify/response_bank/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/Shopify/response_bank/releases/tag/v1.4.0
[1.3.8]: https://github.com/Shopify/response_bank/releases/tag/v1.3.8
[#102]: https://github.com/Shopify/response_bank/pull/102
[#103]: https://github.com/Shopify/response_bank/pull/103
[#112]: https://github.com/Shopify/response_bank/pull/112
