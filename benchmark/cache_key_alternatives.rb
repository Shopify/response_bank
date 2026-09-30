# frozen_string_literal: true

# Investigation only. These candidates do not change ResponseBank at runtime.
# Run both with and without --yjit. Use ROUNDS and ITERATIONS to set sample sizes.
require_relative "cache_key_serialization"
require "active_support"
require "active_support/core_ext/date_time/conversions"
require "msgpack"

module CacheKeyAlternatives
  extend self

  # Native framing for ordinary Ruby containers/scalars. Extension IDs distinguish
  # Symbols, dates, times, oversized Integers, and the existing object fallback.
  FACTORY = MessagePack::Factory.new
  FACTORY.register_type(0, Symbol, packer: :name)
  FACTORY.register_type(1, Time, packer: ->(value) { value.to_i.to_s })
  FACTORY.register_type(1, DateTime, packer: ->(value) { value.to_i.to_s })
  FACTORY.register_type(2, Date, packer: :to_s)
  FACTORY.register_type(3, Integer, packer: :to_s, oversized_integer_extension: true)
  FACTORY.register_type(4, Object, packer: ->(value) { ResponseBank.cache_key_for(value) })
  FACTORY.freeze
  # Preserve input bytes rather than transcoding non-UTF-8 strings.
  POOL = FACTORY.pool(1, compatibility_mode: true)

  def native(data)
    FACTORY.dump(data, compatibility_mode: true)
  end

  def pooled(data)
    POOL.dump(data)
  end

  STRING_HEADERS = Array.new(256) { |n| "s#{n}:".freeze }.freeze
  SYMBOL_HEADERS = Array.new(256) { |n| "y#{n}:".freeze }.freeze
  HASH_HEADERS = Array.new(256) { |n| "h#{n}:".freeze }.freeze
  ARRAY_HEADERS = Array.new(256) { |n| "a#{n}:".freeze }.freeze
  INTEGER_HEADERS = Array.new(256) { |n| "i#{n}:".freeze }.freeze

  # Five bounded, immutable header tables; never retain request data.
  def cached_headers(data)
    append_cached(String.new(capacity: 1024, encoding: Encoding::BINARY), data)
  end

  def append_cached(buffer, data)
    case data
    when String
      length = data.bytesize
      buffer << (STRING_HEADERS[length] || "s#{length}:") << data
    when Symbol
      value = data.name
      length = value.bytesize
      buffer << (SYMBOL_HEADERS[length] || "y#{length}:") << value
    when Hash
      length = data.size
      buffer << (HASH_HEADERS[length] || "h#{length}:")
      data.each do |key, value|
        append_cached(buffer, key)
        append_cached(buffer, value)
      end
    when Array
      length = data.size
      buffer << (ARRAY_HEADERS[length] || "a#{length}:")
      data.each { |value| append_cached(buffer, value) }
    when Integer
      value = data.to_s
      length = value.bytesize
      buffer << (INTEGER_HEADERS[length] || "i#{length}:") << value
    when nil
      buffer << 'n'
    when true
      buffer << 'b1'
    when false
      buffer << 'b0'
    else
      buffer << ResponseBank.cache_key_for(data)
    end
    buffer
  end

  # Same wire format as the current encoder; inline scalar appends and reduce
  # String method calls. No key-specific or input-identity cache.
  def inline(data)
    append_inline(String.new(capacity: 1024, encoding: Encoding::BINARY), data)
  end

  def append_inline(buffer, data)
    case data
    when String
      buffer.concat('s', data.bytesize.to_s, ':', data)
    when Symbol
      name = data.name
      buffer.concat('y', name.bytesize.to_s, ':', name)
    when Hash
      buffer.concat('h', data.size.to_s, ':')
      data.each do |key, value|
        append_inline(buffer, key)
        append_inline(buffer, value)
      end
    when Array
      buffer.concat('a', data.size.to_s, ':')
      data.each { |value| append_inline(buffer, value) }
    when Integer
      value = data.to_s
      buffer.concat('i', value.bytesize.to_s, ':', value)
    when nil
      buffer << 'n'
    when true
      buffer << 'b1'
    when false
      buffer << 'b0'
    else
      # Keep the existing uncommon-type behavior, including custom objects.
      buffer << ResponseBank.cache_key_for(data)
    end
    buffer
  end

  def separate_pair(serializer, input)
    versioned = serializer.call(input)
    base = serializer.call(key: input[:key], key_schema_version: input[:key_schema_version], encoding: input[:encoding])
    ["cacheable:" + Digest::MD5.hexdigest(base), "cacheable:" + Digest::MD5.hexdigest(versioned)]
  end

  # A format change: serialize the key tree once, append a framed version.
  # Keep two raw Strings and two existing hash(String) calls, which also permits
  # SFR's StorefrontResponseCacheHandler#hash override to remain in use.
  def shared_pair(serializer, input)
    base = serializer.call([input[:key_schema_version], input[:encoding], input[:key]])
    versioned = base + serializer.call([input[:version]])
    ["cacheable:" + Digest::MD5.hexdigest(base), "cacheable:" + Digest::MD5.hexdigest(versioned)]
  end

  # Same bytes as the current h3/h4 envelopes, in the handler's field order.
  # This optimization does not require a second cache format change.
  def cached_same_format_raw(input)
    key = cached_headers(input[:key])
    suffix = String.new(encoding: Encoding::BINARY)
    append_cached(suffix, :key_schema_version)
    append_cached(suffix, input[:key_schema_version])
    append_cached(suffix, :encoding)
    append_cached(suffix, input[:encoding])

    base = +'h3:y3:key'
    base << key << suffix
    versioned = +'h4:y3:key'
    versioned << key
    append_cached(versioned, :version)
    append_cached(versioned, input[:version])
    versioned << suffix
    [base, versioned]
  end

  def cached_same_format_pair(input, with_log = false)
    base, versioned = cached_same_format_raw(input)
    base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
    tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
    if with_log
      log = ["Raw cacheable.key: #{versioned}", "cacheable.key: #{tag}"].join(', ')
      [base_hash, tag, log]
    else
      [base_hash, tag]
    end
  end

  def production_pair(input, with_log = false)
    base, versioned = ResponseBank.cache_key_pair_for(
      key: input[:key],
      version: input[:version],
      key_schema_version: input[:key_schema_version],
      encoding: input[:encoding],
    )
    base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
    tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
    return [base_hash, tag] unless with_log

    log = ["Raw cacheable.key: #{versioned}", "cacheable.key: #{tag}"].join(', ')
    [base_hash, tag, log]
  end

  def native_shared_pair(input)
    POOL.packer do |packer|
      packer.write([input[:key_schema_version], input[:encoding], input[:key]])
      base = packer.to_s
      packer.write([input[:version]])
      versioned = packer.full_pack
      ["cacheable:" + Digest::MD5.hexdigest(base), "cacheable:" + Digest::MD5.hexdigest(versioned)]
    end
  end

  def native_shared_pair_with_log(input)
    POOL.packer do |packer|
      packer.write([input[:key_schema_version], input[:encoding], input[:key]])
      base = packer.to_s
      packer.write([input[:version]])
      versioned = packer.full_pack
      base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
      tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
      log = ["Raw cacheable.key: #{versioned.inspect}", "cacheable.key: #{tag}"].join(', ')
      [base_hash, tag, log]
    end
  end

  def native_shared_pair_with_hex_log(input)
    POOL.packer do |packer|
      packer.write([input[:key_schema_version], input[:encoding], input[:key]])
      base = packer.to_s
      packer.write([input[:version]])
      versioned = packer.full_pack
      base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
      tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
      log = ["Raw cacheable.key (hex): #{versioned.unpack1('H*')}", "cacheable.key: #{tag}"].join(', ')
      [base_hash, tag, log]
    end
  end

  def shared_pair_with_log(serializer, input)
    base = serializer.call([input[:key_schema_version], input[:encoding], input[:key]])
    versioned = base + serializer.call([input[:version]])
    base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
    tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
    log = ["Raw cacheable.key: #{versioned}", "cacheable.key: #{tag}"].join(', ')
    [base_hash, tag, log]
  end

  def separate_pair_with_log(serializer, input)
    versioned = serializer.call(input)
    base = serializer.call(key: input[:key], key_schema_version: input[:key_schema_version], encoding: input[:encoding])
    base_hash = "cacheable:" + Digest::MD5.hexdigest(base)
    tag = "cacheable:" + Digest::MD5.hexdigest(versioned)
    log = ["Raw cacheable.key: #{versioned}", "cacheable.key: #{tag}"].join(', ')
    [base_hash, tag, log]
  end

  def candidates
    {
      legacy: method(:legacy_cache_key_for),
      current: ResponseBank.method(:cache_key_for),
      ruby_inline: method(:inline),
      ruby_cached_headers: method(:cached_headers),
      msgpack_factory: method(:native),
      msgpack_pool: method(:pooled),
      inspect: ->(data) { data.inspect },
      json: ->(data) { JSON.generate(data) },
      marshal: ->(data) { Marshal.dump(data) },
    }
  end

  def collision_checks(serializers)
    custom_class = Class.new do
      def to_s
        'example'
      end
      def inspect
        '"example"'
      end
    end
    const_set(:ExampleValue, custom_class) unless const_defined?(:ExampleValue)
    pairs = {
      commas: [{ a: 'a,b', b: 'c' }, { a: 'a', b: 'b,c' }],
      field_names: [{ a: 'x' }, { b: 'x' }],
      symbols: [{ v: :one }, { v: 'one' }],
      key_types: [{ a: 1 }, { 'a' => 1 }],
      integers: [{ v: 1 }, { v: '1' }],
      nesting: [{ v: ['a', ['b']] }, { v: ['a', 'b'] }],
      nil: [{ v: nil }, { v: '' }],
      date: [{ v: Date.new(2026, 1, 1) }, { v: '2026-01-01' }],
      time: [{ v: Time.utc(2026, 1, 1) }, { v: Time.utc(2026, 1, 1).to_s }],
      custom_object: [{ v: ExampleValue.new }, { v: 'example' }],
      binary: [{ a: "\xff,\x00".b, b: 'b' }, { a: "\xff".b, b: "\x00,b".b }],
      unicode: [{ a: 'é,b', b: 'x' }, { a: 'é', b: 'b,x' }],
      oversized_integer: [{ v: 2**80 }, { v: (2**80).to_s }],
    }
    serializers.to_h do |name, serializer|
      results = pairs.to_h do |label, (left, right)|
        result = begin
          serializer.call(key: left) == serializer.call(key: right) ? 'COLLISION' : 'distinct'
        rescue StandardError => error
          error.class.name
        end
        [label, result]
      end
      [name, results]
    end
  end

  def compatibility_checks
    shared = 'same'.dup
    subclass = Class.new(Hash).new.merge(a: 1)
    random = Random.new(81901)
    leaves = [nil, true, false, 0, -1, 2**80, 1.5, :name, 'name', 'é',
      Date.new(2026, 1, 1), Time.utc(2026, 1, 1), DateTime.new(2026, 1, 1)]
    generate = lambda do |depth|
      if depth.zero? || random.rand(3).zero?
        leaves.sample(random: random)
      elsif random.rand(2).zero?
        Array.new(random.rand(5)) { generate.call(depth - 1) }
      else
        random.rand(5).times.to_h { |n| [n.even? ? :"key#{n}" : "key#{n}", generate.call(depth - 1)] }
      end
    end
    values = Array.new(2_000) { generate.call(4) }
    [0, 1, 255, 256, 257, 1000].each do |length|
      values << ('x' * length)
      values << Array.new(length, 'x')
      values << length.times.to_h { |n| [n, 'x'] }
    end
    values.concat([subclass, "\xff\x00".b, ExampleValue.new])
    values.each do |value|
      expected = ResponseBank.cache_key_for(value)
      raise 'cached header bytes differ' unless cached_headers(value) == expected
      input = { key: value, version: { v: 1 }, key_schema_version: 2, encoding: 'br' }
      raise 'shared envelope bytes differ' unless cached_same_format_pair(input) == separate_pair(ResponseBank.method(:cache_key_for), input)
      raise 'production envelope bytes differ' unless production_pair(input) == separate_pair(ResponseBank.method(:cache_key_for), input)
    end
    {
      cached_byte_equivalent_cases: values.length,
      production_pair_equivalent_cases: values.length,
      cached_preserves_hash_subclass_behavior: cached_headers(subclass) == cached_headers({ a: 1 }),
      msgpack_preserves_hash_subclass_behavior: pooled(subclass) == pooled({ a: 1 }),
      marshal_ignores_object_aliasing: Marshal.dump([shared, shared]) == Marshal.dump([shared.dup, shared.dup]),
    }
  end

  def benchmark_group(operations, iterations, rounds)
    operations.each_value { |operation| 10_000.times { operation.call } }
    samples = operations.to_h { |name, _| [name, []] }
    random = Random.new(81901)
    rounds.times do
      operations.keys.shuffle(random: random).each do |name|
        operation = operations.fetch(name)
        GC.start
        start_allocations = GC.stat(:total_allocated_objects)
        elapsed = Benchmark.realtime { iterations.times { operation.call } }
        count = GC.stat(:total_allocated_objects) - start_allocations
        samples[name] << [elapsed * 1_000_000 / iterations, count.fdiv(iterations)]
      end
    end
    samples.transform_values do |rows|
      times = rows.map(&:first).sort
      { median_us: times[times.size / 2], min_us: times.first, max_us: times.last, allocated_objects: rows.map(&:last).sort[rows.size / 2] }
    end
  end

  def run
    iterations = Integer(ENV.fetch('ITERATIONS', 30_000))
    rounds = Integer(ENV.fetch('ROUNDS', 7))
    serializers = candidates
    checks = collision_checks(serializers)
    compatibility = compatibility_checks
    inputs = {
      small: SMALL_KEY_INPUT,
      storefront: STOREFRONT_KEY_INPUT,
      large_params: STOREFRONT_KEY_INPUT.merge(key: STOREFRONT_KEY_DATA.merge(params: 30.times.to_h { |n| ["filter.#{n}", ["value,#{n}", "é" * 40]] })),
    }
    results = inputs.to_h do |label, input|
      operations = serializers.transform_values { |serializer| -> { Digest::MD5.hexdigest(serializer.call(input)) } }
      [label, {
        serialization_and_md5: benchmark_group(operations, iterations, rounds),
        bytes: serializers.transform_values { |serializer| serializer.call(input).bytesize },
      }]
    end
    pairs = serializers.transform_values { |serializer| -> { separate_pair(serializer, STOREFRONT_KEY_INPUT) } }
    pairs[:current_shared] = -> { shared_pair(serializers.fetch(:current), STOREFRONT_KEY_INPUT) }
    pairs[:inline_shared] = -> { shared_pair(serializers.fetch(:ruby_inline), STOREFRONT_KEY_INPUT) }
    pairs[:cached_shared] = -> { shared_pair(serializers.fetch(:ruby_cached_headers), STOREFRONT_KEY_INPUT) }
    pairs[:msgpack_shared] = -> { native_shared_pair(STOREFRONT_KEY_INPUT) }
    pairs[:cached_same_format] = -> { cached_same_format_pair(STOREFRONT_KEY_INPUT) }
    pairs[:production] = -> { production_pair(STOREFRONT_KEY_INPUT) }
    logs = {
      legacy: -> { separate_pair_with_log(serializers.fetch(:legacy), STOREFRONT_KEY_INPUT) },
      current: -> { separate_pair_with_log(serializers.fetch(:current), STOREFRONT_KEY_INPUT) },
      msgpack_shared: -> { native_shared_pair_with_log(STOREFRONT_KEY_INPUT) },
      msgpack_shared_hex: -> { native_shared_pair_with_hex_log(STOREFRONT_KEY_INPUT) },
      cached_shared: -> { shared_pair_with_log(serializers.fetch(:ruby_cached_headers), STOREFRONT_KEY_INPUT) },
      cached_same_format: -> { cached_same_format_pair(STOREFRONT_KEY_INPUT, true) },
      production: -> { production_pair(STOREFRONT_KEY_INPUT, true) },
    }
    puts JSON.pretty_generate(
      runtime: RUBY_DESCRIPTION, msgpack: MessagePack::VERSION, json: JSON::VERSION,
      iterations: iterations, rounds: rounds, collision_checks: checks, compatibility: compatibility, cases: results,
      storefront_pair: benchmark_group(pairs, iterations, rounds),
      storefront_pair_and_log: benchmark_group(logs, iterations, rounds),
    )
  end
end

CacheKeyAlternatives.run if $PROGRAM_NAME == __FILE__
