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

ResponseBank.logger = Class.new { def info(a); end }.new

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

class << ResponseBank
  module ScrubGzipTimestamp
    def compress(*)
      gzip_content = super
      gzip_content = gzip_content.b # get byte-wise access
      # bytes in the range [4, 8) is a timestamp in the GZIP header, which causes flakiness in tests.
      gzip_content[4, 4] = "\0\0\0\0"

      gzip_content
    end
  end
  prepend(ScrubGzipTimestamp)
end

$LOAD_PATH << File.expand_path('../lib', __FILE__)
require 'response_bank'
