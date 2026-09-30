# frozen_string_literal: true

# Run with a supported appraisal bundle:
# BUNDLE_GEMFILE=gemfiles/actionpack_8.0.gemfile bundle exec ruby -Ilib benchmark/cache_key_serialization.rb
# Add --yjit before -Ilib to measure the production execution mode.

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


def previous_cache_key_for(data)
  buffer = String.new(capacity: 256, encoding: Encoding::BINARY)
  previous_append_cache_key_component(buffer, data)
  buffer
end


def previous_append_cache_key_component(buffer, data)
  case data
  when Hash
    buffer << 'h' << data.size.to_s << ':'
    data.each do |key, value|
      previous_append_cache_key_component(buffer, key)
      previous_append_cache_key_component(buffer, value)
    end
  when Array
    buffer << 'a' << data.size.to_s << ':'
    data.each { |value| previous_append_cache_key_component(buffer, value) }
  when String
    previous_append_cache_key_scalar(buffer, 's', data)
  when Symbol
    previous_append_cache_key_scalar(buffer, 'y', data.name)
  when Integer
    previous_append_cache_key_scalar(buffer, 'i', data.to_s)
  when Time, DateTime
    previous_append_cache_key_scalar(buffer, 't', data.to_i.to_s)
  when Date
    previous_append_cache_key_scalar(buffer, 'd', data.to_s)
  when true
    buffer << 'b1'
  when false
    buffer << 'b0'
  when nil
    buffer << 'n'
  else
    buffer << 'o'
    previous_append_cache_key_scalar(buffer, 'c', data.class.name.to_s)
    previous_append_cache_key_scalar(buffer, 'v', data.to_s)
  end
end


def previous_append_cache_key_scalar(buffer, type, value)
  buffer << type << value.bytesize.to_s << ':' << value
end


def median(values)
  sorted = values.sort
  sorted.fetch(sorted.length / 2)
end


def legacy_cache_key_pair(input)
  base = legacy_cache_key_for(
    key: input[:key],
    key_schema_version: input[:key_schema_version],
    encoding: input[:encoding],
  )
  [base, legacy_cache_key_for(input)]
end


def previous_cache_key_pair(input)
  base = previous_cache_key_for(
    key: input[:key],
    key_schema_version: input[:key_schema_version],
    encoding: input[:encoding],
  )
  [base, previous_cache_key_for(input)]
end


def separate_cache_key_pair(input)
  base = ResponseBank.cache_key_for(
    key: input[:key],
    key_schema_version: input[:key_schema_version],
    encoding: input[:encoding],
  )
  [base, ResponseBank.cache_key_for(input)]
end


def optimized_cache_key_pair(input)
  ResponseBank.cache_key_pair_for(
    key: input[:key],
    version: input[:version],
    key_schema_version: input[:key_schema_version],
    encoding: input[:encoding],
  )
end


def digest_pair(pair)
  pair.map { |key| Digest::MD5.hexdigest(key) }
end


def measure(name, input, iterations)
  implementations = {
    legacy: method(:legacy_cache_key_pair),
    separate: method(:separate_cache_key_pair),
    previous: method(:previous_cache_key_pair),
    optimized: method(:optimized_cache_key_pair),
  }

  expected = previous_cache_key_pair(input)
  raise "separate serializer bytes differ" unless separate_cache_key_pair(input) == expected
  raise "optimized serializer bytes differ" unless optimized_cache_key_pair(input) == expected

  results = implementations.to_h do |implementation, serializer|
    WARMUP_ITERATIONS.times { serializer.call(input) }

    serialization_samples = Array.new(SAMPLE_COUNT) do
      GC.start
      Benchmark.realtime { iterations.times { serializer.call(input) } }
    end

    digest_samples = Array.new(SAMPLE_COUNT) do
      GC.start
      Benchmark.realtime do
        iterations.times { digest_pair(serializer.call(input)) }
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
      bytes: output.sum(&:bytesize),
    }

    [implementation, result]
  end

  separate = results.fetch(:separate)
  previous = results.fetch(:previous)
  optimized = results.fetch(:optimized)
  {
    name: name,
    iterations: iterations,
    **results,
    optimized_to_previous: {
      serialization_time: optimized[:serialization_ns] / previous[:serialization_ns],
      digest_time: optimized[:digest_ns] / previous[:digest_ns],
      allocations: optimized[:allocations] / previous[:allocations],
      bytes: optimized[:bytes].fdiv(previous[:bytes]),
    },
    optimized_to_separate: {
      serialization_time: optimized[:serialization_ns] / separate[:serialization_ns],
      digest_time: optimized[:digest_ns] / separate[:digest_ns],
      allocations: optimized[:allocations] / separate[:allocations],
      bytes: optimized[:bytes].fdiv(separate[:bytes]),
    },
  }
end


SMALL_KEY_INPUT = {
  key: { first: "a,b", second: "c" },
  version: { version: 42 },
  key_schema_version: 2,
  encoding: "br",
}

STOREFRONT_KEY_DATA = {
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

STOREFRONT_KEY_INPUT = {
  key: STOREFRONT_KEY_DATA,
  version: { "version" => "2", "shop.version" => 9_876_543 },
  key_schema_version: 2,
  encoding: "br",
}

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate([
    measure("small", SMALL_KEY_INPUT, SMALL_ITERATIONS),
    measure("representative_storefront", STOREFRONT_KEY_INPUT, STOREFRONT_ITERATIONS),
  ])
end
