# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankBrotliSpliceSlotTest < Minitest::Test
  def setup
    @injector = InlineValueInjector.new('a' => 'next-a', 'b' => 'next-b')
    @env = { ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY => @injector }
  end

  def test_encode_body_writes_one_metadata_entry_per_slot
    encoded = encode_body

    slots = encoded.metadata.fetch('brotli_splice').fetch('slots')
    assert_equal(['a', 'b'], slots.map { |slot| slot['name'] })
    assert_equal(
      ['a', 'b'].map { |name| InlineValueInjector::PREPARED.b.index("none-#{name}") },
      slots.map { |slot| slot['html_placeholder_offset'] },
    )
    assert_equal([8, 8], slots.map { |slot| slot['html_placeholder_length'] })
    assert_equal([6, 6], slots.map { |slot| slot['replacement_length'] })
    assert_equal(InlineValueInjector::PREPARED, encoded.body)
    assert_equal(InlineValueInjector::PREPARED.b, Brotli.inflate(encoded.compressed_body))
  end

  def test_replace_compressed_secret_fills_every_slot
    encoded = encode_body

    served = ResponseBank::BrotliSpliceSlot.replace_compressed_secret(@env, encoded.compressed_body, cached(encoded))

    assert_equal(InlineValueInjector::RENDERED.gsub('live-', 'next-').b, Brotli.inflate(served))
  end

  def test_replace_compressed_secret_keeps_the_placeholder_of_a_slot_it_cannot_fill
    encoded = encode_body
    hit_env = {
      ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY => InlineValueInjector.new('a' => 'too-long-a', 'b' => 'next-b'),
    }

    served = ResponseBank::BrotliSpliceSlot.replace_compressed_secret(hit_env, encoded.compressed_body, cached(encoded))

    assert_equal(InlineValueInjector::PREPARED.sub('none-b', 'next-b').b, Brotli.inflate(served))
  end

  def test_encode_body_returns_the_prepared_body_when_its_slots_cannot_be_encoded
    offset_a = InlineValueInjector::PREPARED.b.index('none-a')
    offset_b = InlineValueInjector::PREPARED.b.index('none-b')
    ResponseBank.stubs(:log)

    [
      [],
      [{ name: 'a', offset: offset_a, length: 2 }],
      [{ name: 'a', offset: InlineValueInjector::PREPARED.bytesize, length: 8 }],
      [{ name: 'b', offset: offset_b, length: 8 }, { name: 'a', offset: offset_a, length: 8 }],
      [{ name: 'a', offset: offset_a, length: 8 }, { name: 'b', offset: offset_a + 4, length: 8 }],
    ].each do |slots|
      @injector.slots = slots

      encoded = encode_body

      assert_equal(InlineValueInjector::PREPARED, encoded.body, slots.inspect)
      assert_nil(encoded.compressed_body, slots.inspect)
      assert_nil(encoded.metadata, slots.inspect)
    end
  end

  private

  def encode_body
    ResponseBank::BrotliSpliceSlot.encode_body(@env, InlineValueInjector::RENDERED, {}, compression_level: 5)
  end

  # What a cache hit reads back from the entry.
  def cached(encoded)
    MessagePack.load(MessagePack.dump(encoded.metadata))
  end
end
