# frozen_string_literal: true

require "json"

module AiLineSelection
  module Adapters
    module ExternalSupport
      private

      def ensure_structured_request!(request)
        return if %i[safety meaning abstraction line_evaluation].include?(request.operation)

        raise ProviderContractError.new(
          "External adapter received an unsupported operation",
          operation: request.operation
        )
      end

      def ensure_operation!(request, expected)
        return if request.operation == expected

        raise ProviderContractError.new(
          "External adapter received an unsupported operation",
          operation: request.operation
        )
      end

      def api_key!(request)
        name = request.settings.fetch("api_key_env")
        value = @environment[name].to_s
        return value unless value.empty?

        raise ExternalApiNotConfiguredError.new(request.operation, missing: [name])
      end

      def request_id(response, document = nil)
        response.headers["request-id"] || response.headers["x-request-id"] || document&.fetch("id", nil)
      end

      def parse_outer_json(response, provider)
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise ResponseParseError.new(provider, request_id: request_id(response))
      end

      def parse_structured_json(text, provider:, request_id:, usage:)
        JSON.parse(text)
      rescue JSON::ParserError
        raise ResponseParseError.new(provider, request_id: request_id, usage: usage.to_h)
      end

      def handle_http_error!(response, provider)
        return if response.status.between?(200, 299)

        id = request_id(response)
        case response.status
        when 401, 403
          raise AuthenticationError.new(provider, request_id: id)
        when 429
          raise RateLimitError.new(provider, request_id: id, retry_after: response.headers["retry-after"])
        when 500..599
          raise ProviderServerError.new(provider, status: response.status, request_id: id)
        else
          raise ProviderHttpError.new(
            provider,
            status: response.status,
            request_id: id,
            provider_error: provider_error_details(response)
          )
        end
      end

      def provider_error_details(response)
        error = JSON.parse(response.body).fetch("error", {})
        return unless error.is_a?(Hash)

        error.slice("type", "code", "param", "message").transform_values do |value|
          value.is_a?(String) ? value[0, 1000] : value
        end
      rescue JSON::ParserError
        nil
      end

      def validate_returned_model!(request, returned_model)
        expected = request.model
        return expected if returned_model.to_s.empty?
        return returned_model if returned_model == expected || returned_model.start_with?("#{expected}-")

        raise ProviderContractError.new(
          "Provider returned an unexpected model",
          operation: request.operation,
          details: { expected_model: expected, returned_model: returned_model }
        )
      end

      def pricing(request)
        PricingCalculator.new(
          settings: request.settings,
          usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
        )
      end
    end
  end
end
