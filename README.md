# ResponseBank [![Build Status](https://secure.travis-ci.org/Shopify/response_bank.png)](http://travis-ci.org/Shopify/response_bank) [![CI Status](https://github.com/Shopify/response_bank/actions/workflows/ci.yml/badge.svg)](https://github.com/Shopify/response_bank/actions/workflows/ci.yml)

## Features

* Serve gzip'd content
* Add ETag and 304 Not Modified headers
* Generational caching
* No explicit expiry

## Support

This gem supports the following versions of Ruby and Rails:

* Ruby 3.1.0+
* Rails 6.0.0+

## Usage

1. include the gem in your Gemfile

    ```ruby
    gem 'response_bank'
    ```

2. add an initializer file. We need to configure the `acquire_lock` method, set the cache store and the logger

    ```ruby
    require 'response_bank'

    module ResponseBank
      LOCK_TTL = 90

      class << self
        def acquire_lock(cache_key)
          cache_store.write("#{cache_key}:lock", '1', unless_exist: true, expires_in: LOCK_TTL, raw: true)
        end
      end
    end

    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(Rails.configuration.cache_store)
    ResponseBank.logger = Rails.logger

    ```

3. enables caching on your application

    ```ruby
    config.action_controller.perform_caching = true
    ```

4. use `#response_cache` method to any desired controller's action

    ```ruby
    class PostsController < ApplicationController
      def show
        response_cache do
          @post = @shop.posts.find(params[:id])
          respond_with(@post)
        end
      end
    end
    ```

5. **(optional)** set a custom TTL for the cache by overriding the `write_to_backing_cache_store` method in your initializer file

    ```ruby
    module ResponseBank
      CACHE_TTL = 30.minutes
      def write_to_backing_cache_store(_env, key, payload, expires_in: nil)
        cache_store.write(key, payload, raw: true, expires_in: expires_in || CACHE_TTL)
      end
    end
    ```

6. **(optional)** override custom cache key data. For default, cache key is defined by URL and query string

    ```ruby
    class PostsController < ApplicationController
      before_action :set_shop

      def index
        response_cache do
          @post = @shop.posts
          respond_with(@post)
        end
      end

      def show
        response_cache do
          @post = @shop.posts.find(params[:id])
          respond_with(@post)
        end
      end

      def another_action
        # custom cache key data
        cache_key = {
          action: action_name,
          format: request.format,
          shop_updated_at: @shop.updated_at
          # you may add more keys here
        }
        response_cache cache_key do
          @post = @shop.posts.find(params[:id])
          respond_with(@post)
        end
      end

      # override default cache key data globally per class
      def cache_key_data
        {
          action: action_name,
          format: request.format,
          params: params.slice(:id),
          shop_version: @shop.version
          # you may add more keys here
        }
      end

      def set_shop
        # @shop = ...
      end
    end
    ```

## Completing a deferred cache miss

`ResponseBank::Middleware` can cache a body only when it is complete before the Rack tuple returns. An application that finishes a response later, such as through Rack partial hijack, can defer the cache write during a real ResponseBank miss:

```ruby
deferred_store = ResponseBank.defer_store(env)

# Return the Rack response. Later, after the body was generated and written in full:
cache_headers = headers.dup
cache_headers.delete('Cache-Control') if cache_headers['Cache-Control'] == 'no-cache, no-store'
deferred_store.complete(headers: cache_headers, body: completed_body)

# Run this from the response-finished path. It is a no-op after completion.
deferred_store.abort
```

`defer_store` is a cache-fill lifecycle API. Call it only from a ResponseBank cache-miss path after `ResponseCacheHandler` initialized the request and recorded logical fill-lock ownership. It raises if the request is not a GET cache miss, if required cache context is absent, or if another deferred store is already registered.

The middleware arms the handle after the application returns the Rack tuple. It does not add an ETag to the live deferred response. `complete` copies and filters the final cache headers, adds the cached ETag and `Content-Encoding`, compresses the complete body, and writes the existing MessagePack cache format. It returns `true` when it stores and `false` when the request no longer owns an eligible fill.

Call `complete` only after the intended response was generated and written successfully. Never call it from a rescue or ensure path. Do not complete failed, timed-out, disconnected, or truncated responses. The body must be the shared cache representation and must not contain client-specific data added for the live response.

The headers passed to `complete` describe the cached representation. They can differ from headers already sent to the client. ResponseBank rejects final cache headers that contain `private` or `no-store`, and it does not mutate the supplied hash. It captures the cache timestamp when `defer_store` is called, before deferred rendering and compression.

`abort` is idempotent and releases an owned fill lock through `ResponseBank.release_lock`. Its default implementation is a no-op. The existing `write_to_cache` hook remains responsible for cleanup after a write attempt. An integration that releases those fills from `write_to_cache` should also implement `release_lock` for abandoned fills and failures that happen before the write hook. A key-only lock cannot prevent an old fill from releasing a replacement lock after its lease expires; integrations that need that guarantee must use owner tokens in their lock implementation.

## Cache Entry Metadata

Applications can store a Hash inside a cache entry by setting
`env['cacheable.metadata']` before the response is stored:

```ruby
env['cacheable.metadata'] = { 'variant' => 'b' }
```

On a server cache hit, `env['cacheable.metadata']` holds the Hash stored with the
served entry, stale or fresh; the key is removed when the entry has none. The Hash
is stored once and shared by every request served from the entry, so it must not
contain anything visitor-specific. It is serialized with MessagePack (String keys on
read; unserializable values are logged and the metadata dropped) and nested under
`ResponseBank::APP_METADATA_KEY`, so it cannot collide with ResponseBank's own slots.

## Brotli Splice Slots

Applications that need per-request replacement inside cached Brotli HTML responses can pass an injector builder to `ResponseBank::Middleware`:

```ruby
use ResponseBank::Middleware, ->(env) { HtmlMetadataInjector.new(env) }
```

Rails applications can configure the same builder through `config.response_bank`:

```ruby
config.response_bank.brotli_splice_injector =
  ->(env) { HtmlMetadataInjector.new(env) }
```

The injector is optional. If it is not configured, ResponseBank uses the normal Brotli compression path. Applications own the concrete injector implementation because they know how to read their request-specific metadata.

Injectors may include `ResponseBank::BrotliSpliceInjector` to document the required methods:

```ruby
class HtmlMetadataInjector
  include ResponseBank::BrotliSpliceInjector

  # The per-request value spliced in on cache hits (a 36-byte UUID).
  TOKEN_PLACEHOLDER = "00000000-0000-0000-0000-000000000000"
  # BrotliSplice reserves the LAST 2 bytes of a slot as a fixed "\r\n" context
  # suffix, so a slot must span 2 more bytes than its replaceable region and
  # `replacement_length` always comes back as `slot length - 2`. We let those
  # 2 bytes be a real "\r\n" placed after the tag, where a line break is
  # harmless — the replaceable region is therefore `<uuid>">` (38 bytes).
  CONTEXT_SUFFIX = "\r\n"
  PLACEHOLDER_TAG = %(<meta name="shopify-y" content="#{TOKEN_PLACEHOLDER}">#{CONTEXT_SUFFIX})
  SLOT = %(#{TOKEN_PLACEHOLDER}">#{CONTEXT_SUFFIX}) # 38 replaceable bytes + 2 reserved

  def initialize(env)
    @env = env
  end

  def prepare_response_bank_brotli_splice(body, _headers)
    body_with_placeholder = body.sub("</head>", "#{PLACEHOLDER_TAG}</head>")
    # Use a byte offset: BrotliSplice.encode addresses the slot by bytes.
    offset = body_with_placeholder.b.index(TOKEN_PLACEHOLDER)
    return unless offset

    {
      body: body_with_placeholder,
      slots: [
        {
          name: "shopify_y",
          offset: offset,
          # Include the 2 bytes reserved for the context suffix, or the
          # replacement below will be 2 bytes too long and silently dropped.
          length: SLOT.bytesize,
        },
      ],
    }
  end

  def response_bank_brotli_splice_replacement(slot)
    # Must return EXACTLY slot["replacement_length"] bytes (== slot length - 2).
    # If it does not, ResponseBank skips the splice and serves the neutral
    # placeholder, so guard the length rather than assuming it.
    replacement = %(#{shopify_y}">)
    return unless replacement.bytesize == slot.fetch("replacement_length")

    replacement
  end

  def replace_response_bank_brotli_splice_placeholders(body, slots)
    slots.reduce(body) do |current, slot|
      replacement = response_bank_brotli_splice_replacement(slot)
      next current unless replacement

      offset = slot.fetch("html_placeholder_offset")
      length = slot.fetch("html_placeholder_length")
      suffix = slot.fetch("context_suffix", CONTEXT_SUFFIX)

      # replacement + suffix must equal the original slot length (byteslice
      # replaces `length` bytes), keeping the body byte-for-byte consistent.
      current.byteslice(0, offset) + replacement + suffix +
        current.byteslice(offset + length, current.bytesize)
    end
  end

  private

  def shopify_y
    @env.fetch("HTTP_SHOPIFY_Y") # 36-byte UUID
  end
end
```

`prepare_response_bank_brotli_splice` is used on cache writes. It returns HTML
containing a neutral placeholder and one slot describing that placeholder.
ResponseBank stores the slot metadata with the cached Brotli body. The slot's
`offset` and `length` are **byte** offsets/counts — `BrotliSplice.encode`
addresses the stream by bytes — so locate the placeholder on a binary view
(`body.b.index(...)`) and size it with `bytesize`. A plain `String#index`/`size`
silently breaks once any multi-byte UTF-8 precedes the placeholder: a character
offset is always ≤ the byte length, so the bounds check still passes.

`response_bank_brotli_splice_replacement` is used on Brotli cache hits. It must
return exactly `slot["replacement_length"]` bytes. Note that `replacement_length`
is **2 fewer** than the `length` you registered in the slot: `BrotliSplice.encode`
reserves the last 2 bytes of every slot as a fixed `\r\n` context suffix. So size
your placeholder to include those 2 bytes (as the example does with the trailing
`\r\n`), and have the replacement match `replacement_length`. If the byte length
does not match, ResponseBank **silently skips the splice and serves the neutral
placeholder** — no exception is raised — so guard the length instead of assuming it.

`replace_response_bank_brotli_splice_placeholders` is used when a cached Brotli response is decompressed for a client that does not accept Brotli.

Advanced integrations can still install the per-request injector directly in the Rack env before ResponseBank reads or writes the cached body:

```ruby
env[ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY] = injector
```

## Exception Handling

ResponseBank handles all exceptions gracefully during cache operations. If an exception occurs while reading from cache, deserializing cached data, or writing to cache, the middleware will:

1. **On cache read failures**: Fall back to rendering the page normally (as if it was a cache miss).
2. **On cache write failures**: Still serve the successfully rendered page to the user, but log the cache write failure.

This ensures that issues with cache stores (Redis/Memcached down), serialization errors, or compression/decompression failures don't cause 500 errors for your users.

### Custom Exception Handlers

You can set a custom exception handler in the Rack environment to be notified when cache operations fail (e.g., to report to Bugsnag, Sentry, etc.):

```ruby
# In an initializer or middleware
class MyMiddleware
  def call(env)
    env['response_bank.on_exception'] = ->(e) { Bugsnag.notify(e) }
    @app.call(env)
  end
end
```

## License

ResponseBank is released under the [MIT License](LICENSE.txt).
