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

## License

ResponseBank is released under the [MIT License](LICENSE.txt).
