# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.8] - 2026-07-10

### Added
- Brotli splice cache slot handling: reserve fixed-length slots in a
  Brotli-compressed cached response body and splice per-request values into them
  at serve time, without recompressing the body ([#103]).
- `brotli_splice` as a dependency, powering the splice slot support ([#102]).

Releases prior to 1.3.8 are recorded in the project's git tags and GitHub Releases.

[1.3.8]: https://github.com/Shopify/response_bank/releases/tag/v1.3.8
[#102]: https://github.com/Shopify/response_bank/pull/102
[#103]: https://github.com/Shopify/response_bank/pull/103
