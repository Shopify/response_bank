# frozen_string_literal: true

module ResponseBank
  module BrotliSpliceInjector
    def prepare_response_bank_brotli_splice(body, headers)
      raise NotImplementedError
    end

    def response_bank_brotli_splice_replacement(slot)
      raise NotImplementedError
    end

    def replace_response_bank_brotli_splice_placeholders(body, slots)
      raise NotImplementedError
    end
  end
end
