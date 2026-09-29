# frozen_string_literal: true

# Run with a supported appraisal bundle:
# BUNDLE_GEMFILE=gemfiles/actionpack_8.0.gemfile bundle exec ruby -Ilib benchmark/cache_key_serialization.rb

require "benchmark"
require "date"
require "digest/md5"
require "json"
require "response_bank"

SMALL_ITERATIONS = Integer(ENV.fetch("SMALL_ITERATIONS", 250_000))
STOREFRONT_ITERATIONS = Integer(ENV.fetch("STOREFRONT_ITERATIONS", 50_000))
SAMPLE_COUNT = Integer(ENV.fetch("SAMPLE_COUNT", 7))
WARMUP_ITERATIONS = Integer(ENV.fetch("WARMUP_ITERATIONS", 10_000))


def legacy_cache_key_for(data)
  case data
  when Hash
    return data.inspect unless data.key?(:key)

    key = legacy_hash_value_str(data[:key])
    key = "#{data[:key_schema_version]}:#{key}" if data[:key_schema_version]
    key = "#{key}:#{legacy_hash_value_str(data[:version])}" if data[:version]
    key = "#{key}:#{legacy_hash_value_str(data[:encoding])}" if data[:encoding]
    key
  when Array
    data.inspect
  when Time, DateTime
    data.to_i
  when Date
    data.to_s
  when true, false, Integer, Symbol, String
    data.inspect
  else
    data.to_s.inspect
  end
end


def legacy_hash_value_str(data)
  data.is_a?(Hash) ? data.values.join(",") : data.to_s
end


def median(values)
  sorted = values.sort
  sorted.fetch(sorted.length / 2)
end


def measure(name, input, iterations)
  implementations = {
    legacy: method(:legacy_cache_key_for),
    current: ResponseBank.method(:cache_key_for),
  }

  results = implementations.to_h do |implementation, serializer|
    WARMUP_ITERATIONS.times { serializer.call(input) }

    serialization_samples = Array.new(SAMPLE_COUNT) do
      GC.start
      Benchmark.realtime { iterations.times { serializer.call(input) } }
    end

    digest_samples = Array.new(SAMPLE_COUNT) do
      GC.start
      Benchmark.realtime do
        iterations.times { Digest::MD5.hexdigest(serializer.call(input)) }
      end
    end

    GC.start
    allocated_before = GC.stat(:total_allocated_objects)
    iterations.times { serializer.call(input) }
    allocated_after = GC.stat(:total_allocated_objects)

    output = serializer.call(input)
    result = {
      serialization_ns: median(serialization_samples) * 1_000_000_000 / iterations,
      digest_ns: median(digest_samples) * 1_000_000_000 / iterations,
      allocations: (allocated_after - allocated_before).fdiv(iterations),
      bytes: output.bytesize,
    }

    [implementation, result]
  end

  legacy = results.fetch(:legacy)
  current = results.fetch(:current)
  {
    name: name,
    iterations: iterations,
    legacy: legacy,
    current: current,
    ratios: {
      serialization_time: current[:serialization_ns] / legacy[:serialization_ns],
      digest_time: current[:digest_ns] / legacy[:digest_ns],
      allocations: current[:allocations] / legacy[:allocations],
      bytes: current[:bytes].fdiv(legacy[:bytes]),
    },
  }
end


small = {
  key: { first: "a,b", second: "c" },
  version: { version: 42 },
  key_schema_version: 2,
  encoding: "br",
}

storefront_key = {
  version: "3",
  shop_id: 123_456_789,
  ssl: true,
  format: "text/html",
  hostname: "example.myshopify.com",
  path: "/products/example-product",
  verifier_rule: nil,
  html_metadata_layout: "shopify-y-v1",
  perf_kit_version: 7,
  params: {
    "variant" => "4455667788",
    "section_id" => "main-product",
    "filter.color" => ["red", "blue"],
  },
  shopify_api_features: "",
  browser_dependent_injections: "legacy",
  handheld: false,
  forced_role_theme: "",
  storefront_digest: "",
  currency: "USD",
  currency_rate: "1.0",
  wallets_version: "default",
  shop_pay_emphasis_affinity: false,
  signatures_blob: "0d4f887eaf1ca3cbe6fd56d24c4c6f11",
  eligible_wallets: "47e4f09409cb742f7a36b2ca32201407",
  show_data_sale_opt_out_link: false,
  show_privacy_banner_reshow_link: false,
  experiments: "checkout_redesign=control",
}

storefront = {
  key: storefront_key,
  version: { "version" => "2", "shop.version" => 9_876_543 },
  key_schema_version: 2,
  encoding: "br",
}

puts JSON.pretty_generate([
  measure("small", small, SMALL_ITERATIONS),
  measure("representative_storefront", storefront, STOREFRONT_ITERATIONS),
])
