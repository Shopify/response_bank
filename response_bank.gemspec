# -*- encoding: utf-8 -*-
# frozen_string_literal: true
$LOAD_PATH.push(File.expand_path("../lib", __FILE__))
require "response_bank/version"

Gem::Specification.new do |s|
  s.name        = "response_bank"
  s.version     = ResponseBank::VERSION
  s.license     = "MIT"
  s.authors     = ["Tobias Lütke", "Burke Libbey"]
  s.email       = ["tobi@shopify.com", "burke@burkelibbey.org"]
  s.homepage    = ""
  s.summary     = 'Simple response caching for Ruby applications'

  s.files         = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  s.require_paths = ["lib"]

  s.required_ruby_version = ">= 2.7.0"

  s.metadata["allowed_push_host"] = "https://rubygems.org"

  s.add_runtime_dependency("msgpack")
  s.add_runtime_dependency("brotli")

  # brotli_splice is optional for consumers: only apps that opt into Brotli splice
  # slots need this native extension, so it is not a runtime dependency (they add it
  # to their own Gemfile -- see README). It is a development dependency here so the
  # gem's own test suite, which exercises the splice path directly, can load it --
  # including the actionpack matrix gemfiles in CI, which inherit it through gemspec.
  s.add_development_dependency("brotli_splice", "= 0.1.1")

  s.add_development_dependency("minitest")
  s.add_development_dependency("mocha")
  s.add_development_dependency("rake")
  s.add_development_dependency("rails")
  s.add_development_dependency("simplecov")
end
