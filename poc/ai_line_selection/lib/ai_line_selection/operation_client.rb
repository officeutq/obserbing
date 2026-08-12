# frozen_string_literal: true

module AiLineSelection
  class OperationClient
    def initialize(configuration:, schemas:, prompts:, telemetry:, adapter_override: nil)
      @configuration = configuration
      @schemas = schemas
      @telemetry = telemetry
      @request_builder = RequestBuilder.new(configuration: configuration, schemas: schemas, prompts: prompts)
      @adapter_override = adapter_override
      @validator = SchemaValidator.new
    end

    def call(operation, input, fixture_context: nil)
      request = @request_builder.build(operation, input, fixture_context: fixture_context)
      adapter_name = @adapter_override || @configuration.operation(operation).fetch("adapter")
      adapter = AdapterFactory.build(adapter_name, configuration: @configuration)
      started_at = monotonic_time
      response = adapter.call(request)
      @validator.validate!(operation, request.response_schema, response.data)
      validate_contract!(operation, input, response.data)
      duration_ms = elapsed_ms(started_at)

      metadata = {
        provider: response.provider,
        model: response.model,
        request_id: response.request_id,
        duration_ms: duration_ms,
        usage: response.usage.to_h
      }

      @telemetry.record(
        operation: operation.to_s,
        status: "success",
        duration_ms: duration_ms,
        provider: response.provider,
        model: response.model,
        request_id: response.request_id,
        **response.usage.to_h
      )

      Invocation.new(value: response.data, metadata: metadata)
    rescue AiLineSelection::Error => e
      @telemetry.record(
        operation: operation.to_s,
        status: "error",
        duration_ms: elapsed_ms(started_at),
        error_code: e.code
      )
      raise
    rescue StandardError => e
      wrapped = Error.new(
        "Unexpected adapter error",
        code: "unexpected_adapter_error",
        details: { operation: operation.to_s, error_class: e.class.name }
      )
      @telemetry.record(
        operation: operation.to_s,
        status: "error",
        duration_ms: elapsed_ms(started_at),
        error_code: wrapped.code
      )
      raise wrapped
    end

    private

    def validate_contract!(operation, input, data)
      case operation.to_sym
      when :embedding
        expected_indexes = (0...input.fetch("texts").length).to_a
        actual_indexes = data.fetch("vectors").map { |item| item.fetch("index") }
        unless actual_indexes == expected_indexes
          raise ProviderContractError.new(
            "Embedding indexes do not match inputs",
            operation: operation,
            details: { expected_count: expected_indexes.length, actual_count: actual_indexes.length }
          )
        end
      when :line_evaluation
        allowed_ids = input.fetch("candidates").map { |item| item.fetch("line").fetch("id") }
        actual_ids = data.fetch("candidates").map { |item| item.fetch("line_id") }
        duplicate_ids = actual_ids.tally.select { |_id, count| count > 1 }.keys
        unknown_ids = actual_ids - allowed_ids
        return if duplicate_ids.empty? && unknown_ids.empty?

        raise ProviderContractError.new(
          "Line evaluation returned invalid candidate IDs",
          operation: operation,
          details: { duplicate_ids: duplicate_ids, unknown_ids: unknown_ids }
        )
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      return 0.0 unless started_at

      ((monotonic_time - started_at) * 1000).round(2)
    end
  end
end
