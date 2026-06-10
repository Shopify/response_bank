# frozen_string_literal: true
require 'rails'
require 'active_support/ordered_options'
require 'response_bank/controller'
require 'response_bank/model_extensions'

module ResponseBank
  class Railtie < ::Rails::Railtie
    config.response_bank = ActiveSupport::OrderedOptions.new
    config.response_bank.brotli_splice_injector = nil

    initializer "cachable.configure_active_record" do |app|
      app.config.middleware.insert_after(
        Rack::Head,
        ResponseBank::Middleware,
        app.config.response_bank.brotli_splice_injector,
      )

      ActiveSupport.on_load(:action_controller) do
        include ResponseBank::Controller
      end

      ActiveSupport.on_load(:active_record) do
        include ResponseBank::ModelExtensions
      end
    end
  end
end
