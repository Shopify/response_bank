# frozen_string_literal: true
require 'simplecov'
SimpleCov.start

require 'minitest/autorun'
require 'active_support'
require 'active_support/cache'
require 'active_support/cache/memory_store'
require 'active_support/core_ext/module/deprecation'
require 'rails'
require 'action_controller/railtie'
require 'mocha/minitest'

require 'response_bank'
# response_bank now loads the native brotli_splice gem lazily (only when an app opts
# into splice slots). The test suite exercises that feature directly -- e.g. building
# spliced cache fixtures with BrotliSplice.encode -- so load it explicitly here.
require 'brotli_splice'

ResponseBank.logger = Class.new { def info(a); end }.new

class HtmlMetadataInjector
  include ResponseBank::BrotliSpliceInjector

  PLACEHOLDER_SUFFIX = "##"

  attr_reader :placeholder, :replacement

  def initialize(placeholder:, replacement:)
    @placeholder = placeholder
    @replacement = replacement
  end

  def prepare_response_bank_brotli_splice(body, _headers)
    tag = %(<meta name="shopify-y" content="#{placeholder}#{PLACEHOLDER_SUFFIX}">)
    html = body.sub('</head>', "#{tag}</head>")
    offset = html.index(placeholder)

    {
      body: html,
      slots: [
        {
          name: 'shopify_y',
          offset: offset,
          length: placeholder.bytesize + PLACEHOLDER_SUFFIX.bytesize,
        },
      ],
    }
  end

  def response_bank_brotli_splice_replacement(_slot)
    replacement
  end

  def replace_response_bank_brotli_splice_placeholders(body, slots)
    suffix = slots.first['context_suffix'] || PLACEHOLDER_SUFFIX
    body.sub("#{placeholder}#{suffix}", "#{replacement}#{suffix}")
  end
end

class MockController < ActionController::Base
  def self.after_filter(*args); end

  def headers
    response.headers
  end

  def params
    @params ||= { fill_cache: false }
  end

  def request
    @request ||= Class.new do
      def url
        "http://example.com/"
      end

      def get?
        true
      end

      def env
        @env ||= { 'REQUEST_URI' => '/' }
      end

      def params
        {}
      end
    end.new
  end

  def response
    @response ||= Class.new do
      attr_accessor :body
      def headers
        @headers ||= { 'Status' => 200, 'Content-Type' => 'text/html' }
      end

      def reset_body!
      end
    end.new
  end

  def logger
    ResponseBank.logger
  end

  include ResponseBank::Controller

  def cacheable?
    true
  end
end

$LOAD_PATH << File.expand_path('../lib', __FILE__)
