# frozen_string_literal: true

module AiLineSelection
  class OperationClient
    attr_reader :last_attempts

    def initialize(
      configuration:,
      schemas:,
      prompts:,
      telemetry:,
      adapter_override: nil,
      allow_external_api: false,
      environment: ENV,
      transport: nil,
      sleeper: ->(seconds) { sleep(seconds) }
    )
      @configuration = configuration
      @schemas = schemas
      @telemetry = telemetry
      @request_builder = RequestBuilder.new(configuration: configuration, schemas: schemas, prompts: prompts)
      @adapter_override = adapter_override
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @sleeper = sleeper
      @validator = SchemaValidator.new
      @last_attempts = []
    end

    def call(operation, input, fixture_context: nil, settings: nil)
      settings ||= @configuration.operation(operation)
      request = @request_builder.build(operation, input, fixture_context: fixture_context, settings: settings)
      adapter_name = @adapter_override || settings.fetch("adapter")
      adapter = AdapterFactory.build(
        adapter_name,
        configuration: @configuration,
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
      max_retries = settings.fetch("max_retries", 0).to_i
      @last_attempts = []
      attempt = 0

      begin
        attempt += 1
        response = nil
        started_at = monotonic_time
        response = adapter.call(request)
        @validator.validate!(operation, request.response_schema, response.data)
        validate_contract!(operation, input, response.data)
        duration_ms = elapsed_ms(started_at)
        attempt_record = success_attempt(attempt, duration_ms, response)
        @last_attempts << attempt_record
        record_success(operation, attempt_record)

        Invocation.new(
          value: response.data,
          metadata: {
            provider: response.provider,
            model: response.model,
            request_id: response.request_id,
            duration_ms: @last_attempts.sum { |item| item.fetch(:duration_ms) }.round(2),
            usage: combined_usage(@last_attempts),
            attempts: @last_attempts.map(&:dup),
            attempt_count: attempt,
            retry_count: attempt - 1,
            first_attempt_success: attempt == 1
          }
        )
      rescue AiLineSelection::Error => e
        duration_ms = elapsed_ms(started_at)
        attempt_record = error_attempt(attempt, duration_ms, e, response)
        @last_attempts << attempt_record
        retrying = e.retryable && attempt <= max_retries
        record_error(operation, attempt_record, retrying: retrying)
        if retrying
          @sleeper.call(retry_delay(settings, e))
          retry
        end
        raise
      rescue StandardError => e
        wrapped = Error.new(
          "Unexpected adapter error",
          code: "unexpected_adapter_error",
          details: { operation: operation.to_s, error_class: e.class.name }
        )
        duration_ms = elapsed_ms(started_at)
        attempt_record = error_attempt(attempt, duration_ms, wrapped, response)
        @last_attempts << attempt_record
        record_error(operation, attempt_record, retrying: false)
        raise wrapped
      end
    end

    private

    def success_attempt(attempt, duration_ms, response)
      {
        attempt: attempt,
        retry_count: attempt - 1,
        status: attempt == 1 ? "success" : "retry_success",
        duration_ms: duration_ms,
        provider: response.provider,
        model: response.model,
        request_id: response.request_id,
        usage: response.usage.to_h
      }
    end

    def error_attempt(attempt, duration_ms, error, response)
      usage = response&.usage&.to_h || safe_error_usage(error) || Usage.zero.to_h
      {
        attempt: attempt,
        retry_count: attempt - 1,
        status: "error",
        duration_ms: duration_ms,
        provider: response&.provider || error.details[:provider],
        model: response&.model,
        request_id: response&.request_id || error.details[:request_id],
        usage: usage,
        error_code: error.code,
        missing_required_count: missing_required_count(error)
      }.compact
    end

    def safe_error_usage(error)
      usage = error.details[:usage]
      return unless usage.is_a?(Hash)

      Usage.zero.to_h.merge(usage.transform_keys(&:to_sym)).slice(*Usage.zero.to_h.keys)
    end

    def record_success(operation, attempt)
      @telemetry.record(
        operation: operation.to_s,
        status: attempt.fetch(:status),
        duration_ms: attempt.fetch(:duration_ms),
        provider: attempt[:provider],
        model: attempt[:model],
        request_id: attempt[:request_id],
        attempt: attempt.fetch(:attempt),
        retry_count: attempt.fetch(:retry_count),
        **attempt.fetch(:usage)
      )
    end

    def record_error(operation, attempt, retrying:)
      @telemetry.record(
        operation: operation.to_s,
        status: retrying ? "retrying" : "error",
        duration_ms: attempt.fetch(:duration_ms),
        provider: attempt[:provider],
        model: attempt[:model],
        request_id: attempt[:request_id],
        attempt: attempt.fetch(:attempt),
        retry_count: attempt.fetch(:retry_count),
        error_code: attempt.fetch(:error_code),
        **attempt.fetch(:usage)
      )
    end

    def combined_usage(attempts)
      attempts.each_with_object(Usage.zero.to_h) do |attempt, total|
        usage = attempt.fetch(:usage)
        %i[input_units output_units cached_input_units].each { |key| total[key] += usage.fetch(key, 0).to_i }
        %i[estimated_cost_usd estimated_cost_jpy].each { |key| total[key] += usage.fetch(key, 0).to_f }
      end.tap do |total|
        total[:estimated_cost_usd] = total[:estimated_cost_usd].round(8)
        total[:estimated_cost_jpy] = total[:estimated_cost_jpy].round(4)
      end
    end

    def missing_required_count(error)
      return 0 unless error.is_a?(SchemaValidationError)

      error.details.fetch(:errors, []).count { |message| message.end_with?(": is required") }
    end

    def retry_delay(settings, error)
      provider_delay = error.details[:retry_after].to_f
      configured_delay = settings.fetch("retry_delay_seconds", 0).to_f
      [[provider_delay.positive? ? provider_delay : configured_delay, 0.0].max, 5.0].min
    end

    def validate_contract!(operation, input, data)
      case operation.to_sym
      when :meaning
        validate_meaning_contract!(data)
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

    def validate_meaning_contract!(data)
      errors = []
      themes = data.fetch("themes")
      errors << "themes_count" unless themes.length.between?(1, 4)
      errors << "theme_length" unless themes.all? { |theme| theme.length.between?(1, 30) }
      errors << "structure_length" unless data.fetch("structure").length.between?(1, 200)
      errors << "abstraction_length" unless data.fetch("abstraction").length.between?(1, 120)
      return if errors.empty?

      raise SchemaValidationError.new(:meaning, errors)
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
