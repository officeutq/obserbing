# frozen_string_literal: true

require "json"

module AiLineSelection
  module Adapters
    class OpenAI < Base
      include ExternalSupport

      def initialize(configuration:, environment: ENV, transport: HttpTransport.new)
        @configuration = configuration
        @environment = environment
        @transport = transport
      end

      def call(request)
        ensure_meaning_request!(request)
        provider = request.settings.fetch("provider")
        response = @transport.post(
          url: request.settings.fetch("endpoint"),
          headers: {
            "authorization" => "Bearer #{api_key!(request)}",
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

        if document["status"] == "incomplete"
          reason = document.dig("incomplete_details", "reason")
          raise IncompleteResponseError.new(provider, request_id: id, reason: reason, usage: usage.to_h)
        end

        content = Array(document["output"]).flat_map { |item| Array(item["content"]) }
        raise ProviderRefusalError.new(provider, request_id: id) if content.any? { |item| item["type"] == "refusal" }

        output_text = content.find { |item| item["type"] == "output_text" }&.fetch("text", nil)
        raise IncompleteResponseError.new(provider, request_id: id, reason: "missing_output_text", usage: usage.to_h) unless output_text

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
          instructions: request.prompt,
          input: request.input.fetch("entry_text"),
          reasoning: { effort: request.settings.fetch("reasoning_effort") },
          text: {
            format: {
              type: "json_schema",
              name: "meaning_structure",
              strict: true,
              schema: request.response_schema
            }
          },
          max_output_tokens: request.settings.fetch("max_output_tokens"),
          store: false
        }
      end

      def usage_for(document, request)
        input = document.dig("usage", "input_tokens").to_i
        output = document.dig("usage", "output_tokens").to_i
        cached = document.dig("usage", "input_tokens_details", "cached_tokens").to_i
        pricing(request).usage(input_units: input, output_units: output, cached_input_units: cached)
      end
    end
  end
end
