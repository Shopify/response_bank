# Cacheable

Note: Copied from http://www.slideshare.net/jduff/how-shopify-scales-rails-20443485

* Serve gzip'd content
* ETag and 304 Not Modified
* Generational caching
* No explicit expiry

## Usage

```ruby
class PostsController < ApplicationController
  def show
    response_cache do
      @post = @shop.posts.find(params[:id])
      respond_with(@post)
    end
  end
  
  def cache_key_data
    {
      :action => action_name,
      :format => request.format,
      :params => params.slice(:id),
      :shop_version => @shop.version
     }
   end
end 
```

Copyright 2012 Shopify; MIT License

[![Build Status](https://secure.travis-ci.org/Shopify/cacheable.png)](http://travis-ci.org/Shopify/cacheable)

