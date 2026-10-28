# frozen_string_literal: true

module ResponseBank
  module BrotliSpliceSlot
    INJECTOR_ENV_KEY = 'response_bank.html_metadata_injector'
    METADATA_KEY = 'brotli_splice'
    METADATA_VERSION = 1
    # BrotliSplice reserves the last 2 bytes of every slot as a fixed "\r\n" context
    # suffix, so a slot must be longer than that to hold any replaceable content --
    # BrotliSplice.encode_slots raises unless every slot length exceeds it.
    CONTEXT_SUFFIX_LENGTH = 2

    EncodedBody = Struct.new(:body, :compressed_body, :metadata, keyword_init: true)

    class << self
      # Returns nil when the injector does not prepare the body. Once it does, the
      # prepared body is the shared copy, so the response is never cached as rendered:
      # without a prepared body this raises, and nothing is cached; if its slots cannot
      # be encoded, the result carries that body without a compressed body or metadata,
      # so the caller compresses it normally.
      def encode_body(env, body, headers, compression_level:)
        injector = env[INJECTOR_ENV_KEY]
        return unless injector
        return unless body && body != ''

        prepared = injector.prepare_response_bank_brotli_splice(body, headers)
        return unless prepared

        prepared_body = hash_fetch(prepared, :body)
        raise ArgumentError, 'prepare_response_bank_brotli_splice returned no :body' unless prepared_body

        slots = html_slots(prepared_body, hash_fetch(prepared, :slots))
        unless slots
          ResponseBank.log('BrotliSplice encode skipped: invalid slot')
          return EncodedBody.new(body: prepared_body)
        end

        # Load the native gem only once we have real splice work to do. Keeping this
        # outside the begin/rescue below is deliberate: the rescue clause references
        # BrotliSplice::Error, so if the gem is missing, evaluating that clause would
        # raise NameError and mask the LoadError we want the caller to see.
        ensure_brotli_splice_loaded!

        begin
          result = BrotliSplice.encode_slots(
            prepared_body,
            slots.map { |slot| [slot[:offset], slot[:length]] },
            quality: compression_level,
          )
          compressed_slots = slots.zip(result[:slots]).map do |slot, compressed_slot|
            {
              name: slot[:name],
              compressed_offset: compressed_slot[:offset],
              replacement_length: compressed_slot[:length],
              html_placeholder_offset: slot[:offset],
              html_placeholder_length: slot[:length],
              context_suffix: result[:context_suffix],
            }
          end

          EncodedBody.new(
            body: prepared_body,
            compressed_body: result[:data],
            metadata: metadata_for(compressed_slots),
          )
        rescue BrotliSplice::Error, ArgumentError => error
          ResponseBank.log("BrotliSplice encode skipped: #{error.class}")
          EncodedBody.new(body: prepared_body)
        end
      end

      def metadata_for(slots)
        {
          METADATA_KEY => {
            'version' => METADATA_VERSION,
            'slots' => slots.map { |slot| slot_metadata(**slot) },
          },
        }
      end

      def replace_compressed_secret(env, body, metadata)
        injector = env[INJECTOR_ENV_KEY]
        slots = metadata_slots(metadata)
        return body unless injector && slots && body && body != ''

        # See encode_body: load outside the begin/rescue so a missing gem surfaces as
        # LoadError rather than a masked NameError from the BrotliSplice::Error clause.
        ensure_brotli_splice_loaded!

        begin
          # A slot that cannot be filled keeps its neutral placeholder; the others are
          # still written, with a single copy of the body.
          replacements = slots.filter_map { |slot| compressed_replacement(injector, body, slot) }
          return body if replacements.empty?

          BrotliSplice.replace_slots(body, replacements)
        rescue BrotliSplice::Error, ArgumentError => error
          ResponseBank.log("BrotliSplice replace skipped: #{error.class}")
          body
        end
      end

      def replace_plain_body(env, body, metadata)
        injector = env[INJECTOR_ENV_KEY]
        slots = metadata_slots(metadata)
        return body unless injector && slots && body && body != ''

        injector.replace_response_bank_brotli_splice_placeholders(body, slots)
      rescue ArgumentError => error
        ResponseBank.log("BrotliSplice plain replacement skipped: #{error.class}")
        body
      end

      def metadata_slots(metadata)
        return unless metadata

        brotli_splice = metadata[METADATA_KEY]
        return unless brotli_splice && brotli_splice['version'] == METADATA_VERSION

        brotli_splice['slots']
      end

      private

      # Load the native brotli_splice gem on first use. It is an optional dependency:
      # apps opt into Brotli splice slots by installing an injector, and only those
      # apps need the gem. If it is missing when we actually need it, fail loudly with
      # a pointer to the fix rather than limping along.
      def ensure_brotli_splice_loaded!
        return if @brotli_splice_loaded

        begin
          gem('brotli_splice', '>= 0.3.0')
          require('brotli_splice')
        rescue LoadError => error
          warn(
            'The Brotli splice slot feature requires the "brotli_splice" gem, version 0.3.0 or newer. ' \
            'Add it to your application Gemfile.',
          )
          raise error
        end

        @brotli_splice_loaded = true
      end

      def slot_metadata(
        name:,
        compressed_offset:,
        replacement_length:,
        html_placeholder_offset:,
        html_placeholder_length:,
        context_suffix:
      )
        {
          'name' => name.to_s,
          'compressed_offset' => compressed_offset,
          'replacement_length' => replacement_length,
          'html_placeholder_offset' => html_placeholder_offset,
          'html_placeholder_length' => html_placeholder_length,
          'context_suffix' => context_suffix,
        }
      end

      # Returns the injector's slots with Integer byte ranges, or nil unless there is
      # at least one slot and every range fits the body. BrotliSplice.encode_slots
      # checks that the ranges are ascending and do not overlap.
      def html_slots(body, slots)
        return unless slots.is_a?(Array) && !slots.empty?

        slots.map do |slot|
          offset = integer_value(hash_fetch(slot, :offset))
          length = integer_value(hash_fetch(slot, :length))
          return unless valid_html_slot?(body, offset, length)

          { name: hash_fetch(slot, :name).to_s, offset: offset, length: length }
        end
      end

      def compressed_replacement(injector, body, slot)
        replacement = replacement_for_slot(injector, slot)

        unless valid_replacement?(replacement, slot)
          got = replacement ? replacement.bytesize : 'nil'
          ResponseBank.log(
            'BrotliSplice replace skipped: replacement length mismatch ' \
            "(got #{got}, want #{slot['replacement_length']})",
          )
          return
        end

        offset = integer_value(slot['compressed_offset'])
        length = integer_value(slot['replacement_length'])

        unless valid_compressed_slot?(body, offset, length)
          ResponseBank.log('BrotliSplice replace skipped: compressed slot out of bounds')
          return
        end

        [replacement, offset, length]
      end

      def replacement_for_slot(injector, slot)
        injector.response_bank_brotli_splice_replacement(slot)
      end

      def valid_replacement?(replacement, slot)
        return false unless replacement

        replacement.bytesize == slot['replacement_length']
      end

      def valid_compressed_slot?(body, offset, length)
        return false unless offset && length
        return false unless offset >= 0 && length > 0

        offset + length <= body.bytesize
      end

      def valid_html_slot?(body, offset, length)
        return false unless offset && length
        return false unless offset >= 0 && length > CONTEXT_SUFFIX_LENGTH

        offset + length <= body.bytesize
      end

      def integer_value(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def hash_fetch(hash, key)
        hash[key] || hash[key.to_s]
      end
    end
  end
end
