# frozen_string_literal: true

module AiLineSelection
  module Adapters
    class PendingExternal < Base
      def initialize(configuration:, environment: ENV)
        @configuration = configuration
        @environment = environment
      end

      def call(request)
        raise ExternalApiDisabledError.new(request.operation) unless @configuration.external_api_enabled?

        missing = []
        missing << "provider" if blank_or_fixture?(request.provider)
        missing << "model" if blank_or_fixture?(request.model)

        api_key_env = @configuration.external_api.fetch("api_key_env")
        missing << api_key_env if @environment[api_key_env].to_s.empty?

        raise ExternalApiNotConfiguredError.new(request.operation, missing: missing) unless missing.empty?

        # 外部ProviderのSDK / HTTP呼び出しを追加する位置。現段階では必ず停止する。
        raise ExternalApiNotImplementedError.new(request.operation)
      end

      private

      def blank_or_fixture?(value)
        value.to_s.empty? || value.to_s == "fixture" || value.to_s.start_with?("offline-")
      end
    end
  end
end
