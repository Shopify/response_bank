# frozen_string_literal: true

module ResponseBank
  module BrotliSpliceSlot
    INJECTOR_ENV_KEY = 'response_bank.html_metadata_injector'
    METADATA_KEY = 'brotli_splice'
    METADATA_VERSION = 1
    # BrotliSplice reserves the last 2 bytes of every slot as a fixed "\r\n" context
    # suffix, so a slot must be longer than that to hold any replaceable content --
    # BrotliSplice.encode raises unless the slot length exceeds it.
    CONTEXT_SUFFIX_LENGTH = 2

    EncodedBody = Struct.new(:body, :compressed_body, :metadata, keyword_init: true)

    class << self
      def encode_body(env, body, headers, compression_level:)
        injector = env[INJECTOR_ENV_KEY]
        return unless injector
        return unless body && body != ''

        prepared = injector.prepare_response_bank_brotli_splice(body, headers)
        return unless prepared

        prepared_body = hash_fetch(prepared, :body)
        slots = hash_fetch(prepared, :slots)
        return unless prepared_body && slots && slots.length == 1

        slot = slots.first
        slot_name = hash_fetch(slot, :name).to_s
        html_offset = integer_value(hash_fetch(slot, :offset))
        html_length = integer_value(hash_fetch(slot, :length))
        return unless valid_html_slot?(prepared_body, html_offset, html_length)

        # Load the native gem only once we have real splice work to do. Keeping this
        # outside the begin/rescue below is deliberate: the rescue clause references
        # BrotliSplice::Error, so if the gem is missing, evaluating that clause would
        # raise NameError and mask the LoadError we want the caller to see.
        ensure_brotli_splice_loaded!

        begin
          result = BrotliSplice.encode(prepared_body, html_offset, html_length, quality: compression_level)

          metadata_slot = {
            'name' => slot_name,
            'compressed_offset' => result[:secret_offset],
            'replacement_length' => result[:secret_length],
            'html_placeholder_offset' => html_offset,
            'html_placeholder_length' => html_length,
          }
          metadata_slot['context_suffix'] = result[:context_suffix] if result[:context_suffix]

          EncodedBody.new(
            body: prepared_body,
            compressed_body: result[:data],
            metadata: {
              METADATA_KEY => {
                'version' => METADATA_VERSION,
                'slots' => [metadata_slot],
              },
            },
          )
        rescue BrotliSplice::Error, ArgumentError => error
          ResponseBank.log("BrotliSplice encode skipped: #{error.class}")
          nil
        end
      end

      def replace_compressed_secret(env, body, metadata)
        injector = env[INJECTOR_ENV_KEY]
        slots = metadata_slots(metadata)
        return body unless injector && slots && body && body != ''

        # See encode_body: load outside the begin/rescue so a missing gem surfaces as
        # LoadError rather than a masked NameError from the BrotliSplice::Error clause.
        ensure_brotli_splice_loaded!

        begin
          slots.reduce(body) do |current_body, slot|
            replacement = replacement_for_slot(injector, slot)

            unless valid_replacement?(replacement, slot)
              got = replacement ? replacement.bytesize : 'nil'
              ResponseBank.log(
                'BrotliSplice replace skipped: replacement length mismatch ' \
                "(got #{got}, want #{slot['replacement_length']})",
              )
              next current_body
            end

            offset = integer_value(slot['compressed_offset'])
            length = integer_value(slot['replacement_length'])

            unless valid_compressed_slot?(current_body, offset, length)
              ResponseBank.log('BrotliSplice replace skipped: compressed slot out of bounds')
              next current_body
            end

            BrotliSplice.replace(current_body, replacement, offset, length)
          end
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
          gem('brotli_splice')
          require('brotli_splice')
        rescue LoadError => error
          warn(
            'The Brotli splice slot feature requires the "brotli_splice" gem. ' \
            'Add it to your application Gemfile.',
          )
          raise error
        end

        @brotli_splice_loaded = true
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
