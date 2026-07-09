# ResponseBank [![Build Status](https://secure.travis-ci.org/Shopify/response_bank.png)](http://travis-ci.org/Shopify/response_bank) [![CI Status](https://github.com/Shopify/response_bank/actions/workflows/ci.yml/badge.svg)](https://github.com/Shopify/response_bank/actions/workflows/ci.yml)

## Features

* Serve gzip'd content
* Add ETag and 304 Not Modified headers
* Generational caching
* No explicit expiry

## Support

This gem supports the following versions of Ruby and Rails:

* Ruby 2.7.0+
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

## License

ResponseBank is released under the [MIT License](LICENSE.txt).
