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

  PLACEHOLDER = "00000000-0000-0000-0000-000000000000"
  PLACEHOLDER_TAG = %(<meta name="shopify-y" content="#{PLACEHOLDER}">)

  def initialize(env)
    @env = env
  end

  def prepare_response_bank_brotli_splice(body, _headers)
    body_with_placeholder = body.sub("</head>", "#{PLACEHOLDER_TAG}</head>")
    offset = body_with_placeholder.index(PLACEHOLDER)
    return unless offset

    {
      body: body_with_placeholder,
      slots: [
        {
          name: "shopify-y",
          offset: offset,
          length: PLACEHOLDER.bytesize,
        },
      ],
    }
  end

  def response_bank_brotli_splice_replacement(slot)
    shopify_y.ljust(slot.fetch("replacement_length"))
  end

  def replace_response_bank_brotli_splice_placeholders(body, slots)
    slots.reduce(body) do |current, slot|
      replacement = response_bank_brotli_splice_replacement(slot)
      offset = slot.fetch("html_placeholder_offset")
      length = slot.fetch("html_placeholder_length")

      current.byteslice(0, offset) + replacement + current.byteslice(offset + length, current.bytesize)
    end
  end

  private

  def shopify_y
    @env.fetch("HTTP_SHOPIFY_Y")
  end
end
```

`prepare_response_bank_brotli_splice` is used on cache writes. It returns HTML containing a neutral placeholder and one slot describing that placeholder. ResponseBank stores the slot metadata with the cached Brotli body.

`response_bank_brotli_splice_replacement` is used on Brotli cache hits. It must return replacement bytes with the same byte length as the stored slot.

`replace_response_bank_brotli_splice_placeholders` is used when a cached Brotli response is decompressed for a client that does not accept Brotli.

Advanced integrations can still install the per-request injector directly in the Rack env before ResponseBank reads or writes the cached body:

```ruby
env[ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY] = injector
```

## License

ResponseBank is released under the [MIT License](LICENSE.txt).
