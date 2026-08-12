# frozen_string_literal: true

require "json"

module AiLineSelection
  module Adapters
    class Anthropic < Base
      include ExternalSupport

      def initialize(configuration:, environment: ENV, transport: HttpTransport.new)
        @configuration = configuration
        @environment = environment
        @transport = transport
      end

      def call(request)
        ensure_structured_request!(request)
        provider = request.settings.fetch("provider")
        response = @transport.post(
          url: request.settings.fetch("endpoint"),
          headers: {
            "x-api-key" => api_key!(request),
            "anthropic-version" => request.settings.fetch("api_version"),
            "content-type" => "application/json"
          },
          body: JSON.generate(request_body(request)),
          timeout_seconds: request.timeout_seconds,
          provider: provider
        )
        handle_http_error!(response, provider)
        document = parse_outer_json(response, provider)
        id = request_id(response, document)
        usage = usage_for(document, request)

        if document["stop_reason"] == "refusal"
          raise ProviderRefusalError.new(provider, request_id: id)
        end
        if document["stop_reason"] == "max_tokens"
          raise IncompleteResponseError.new(provider, request_id: id, reason: "max_tokens", usage: usage.to_h)
        end

        output_text = Array(document["content"]).find { |item| item["type"] == "text" }&.fetch("text", nil)
        raise IncompleteResponseError.new(provider, request_id: id, reason: "missing_text", usage: usage.to_h) unless output_text

        AdapterResponse.new(
          data: parse_structured_json(output_text, provider: provider, request_id: id, usage: usage),
          provider: provider,
          model: validate_returned_model!(request, document["model"]),
          request_id: id,
          usage: usage
        )
      end

      private

      def request_body(request)
        {
          model: request.model,
          system: request.prompt,
          messages: [{ role: "user", content: user_input(request) }],
          max_tokens: request.settings.fetch("max_output_tokens"),
          output_config: {
            effort: request.settings.fetch("reasoning_effort"),
            format: {
              type: "json_schema",
              schema: request.response_schema
            }
          }
        }
      end

      def user_input(request)
        return request.input.fetch("entry_text") if request.operation == :meaning

        JSON.generate(request.input)
      end

      def usage_for(document, request)
        raw = document.fetch("usage", {})
        cache_read = raw.fetch("cache_read_input_tokens", 0).to_i
        cache_creation = raw.fetch("cache_creation_input_tokens", 0).to_i
        input = raw.fetch("input_tokens", 0).to_i + cache_read + cache_creation
        pricing(request).usage(
          input_units: input,
          output_units: raw.fetch("output_tokens", 0).to_i,
          cached_input_units: cache_read
        )
      end
    end
  end
end
