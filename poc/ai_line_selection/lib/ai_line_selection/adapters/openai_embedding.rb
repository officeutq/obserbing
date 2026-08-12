# frozen_string_literal: true

require "json"

module AiLineSelection
  module Adapters
    class OpenAIEmbedding < Base
      include ExternalSupport

      def initialize(configuration:, environment: ENV, transport: HttpTransport.new)
        @configuration = configuration
        @environment = environment
        @transport = transport
      end

      def call(request)
        ensure_operation!(request, :embedding)
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
        vectors = Array(document["data"]).sort_by { |item| item.fetch("index") }.map do |item|
          {
            "index" => item.fetch("index"),
            "values" => item.fetch("embedding")
          }
        end

        AdapterResponse.new(
          data: { "schema_version" => "draft-1", "vectors" => vectors },
          provider: provider,
          model: validate_returned_model!(request, document["model"]),
          request_id: id,
          usage: usage
        )
      rescue KeyError, TypeError
        raise ProviderContractError.new(
          "OpenAI Embeddings response is missing required fields",
          operation: request.operation,
          details: { provider: request.settings.fetch("provider") }
        )
      end

      private

      def request_body(request)
        {
          model: request.model,
          input: request.input.fetch("texts"),
          encoding_format: "float",
          dimensions: request.settings.fetch("dimensions")
        }
      end

      def usage_for(document, request)
        input = document.dig("usage", "prompt_tokens").to_i
        pricing(request).usage(input_units: input, output_units: 0)
      end
    end
  end
end
