# frozen_string_literal: true

module AiLineSelection
  class RequestBuilder
    def initialize(configuration:, schemas:, prompts:)
      @configuration = configuration
      @schemas = schemas
      @prompts = prompts
    end

    def build(operation, input, fixture_context: nil)
      settings = @configuration.operation(operation)
      PreparedRequest.new(
        operation: operation.to_sym,
        provider: settings.fetch("provider"),
        model: settings.fetch("model"),
        prompt_version: settings["prompt_version"],
        schema_version: settings.fetch("schema_version"),
        prompt: @prompts.fetch(operation),
        response_schema: @schemas.fetch(operation),
        input: input,
        fixture_context: fixture_context,
        timeout_seconds: settings.fetch("timeout_seconds")
      )
    end

    def redacted_summary(operation, input)
      request = build(operation, input)
      {
        operation: request.operation,
        provider: request.provider,
        model: request.model,
        prompt_version: request.prompt_version,
        schema_version: request.schema_version,
        timeout_seconds: request.timeout_seconds,
        response_schema_id: request.response_schema["$id"],
        prompt_chars: request.prompt&.length || 0,
        input: redact(request.input)
      }
    end

    private

    def redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key] = sensitive_key?(key) ? redacted_value(child) : redact(child)
        end
      when Array
        { count: value.length, redacted: true }
      when String
        redacted_value(value)
      else
        value
      end
    end

    def sensitive_key?(key)
      %w[body entry_text text meaning prompt candidates texts].include?(key.to_s)
    end

    def redacted_value(value)
      length = value.respond_to?(:length) ? value.length : nil
      { redacted: true, length: length }
    end
  end
end
