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

  s.add_development_dependency("minitest", ">= 5.18.0")
  s.add_development_dependency("mocha", ">= 2.0.0")
  s.add_development_dependency("rake")
  s.add_development_dependency("rails", ">= 6.1")
end
