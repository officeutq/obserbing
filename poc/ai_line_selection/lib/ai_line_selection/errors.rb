# frozen_string_literal: true

module AiLineSelection
  class Error < StandardError
    attr_reader :code, :retryable, :details

    def initialize(message, code:, retryable: false, details: {})
      super(message)
      @code = code
      @retryable = retryable
      @details = details.freeze
    end
  end

  class ConfigurationError < Error
    def initialize(message, details: {})
      super(message, code: "configuration_error", details: details)
    end
  end

  class DataError < Error
    def initialize(message, details: {})
      super(message, code: "data_error", details: details)
    end
  end

  class SchemaValidationError < Error
    def initialize(operation, validation_errors)
      super(
        "#{operation} response did not satisfy its JSON Schema",
        code: "schema_validation_error",
        retryable: true,
        details: { operation: operation.to_s, errors: validation_errors }
      )
    end
  end

  class ProviderContractError < Error
    def initialize(message, operation:, details: {})
      super(
        message,
        code: "provider_contract_error",
        retryable: false,
        details: details.merge(operation: operation.to_s)
      )
    end
  end

  class ExternalApiDisabledError < Error
    def initialize(operation)
      super(
        "External AI API is disabled; request stopped before network access",
        code: "external_api_disabled",
        details: { operation: operation.to_s }
      )
    end
  end

  class ExternalApiNotConfiguredError < Error
    def initialize(operation, missing:)
      super(
        "External AI API is not configured",
        code: "external_api_not_configured",
        details: { operation: operation.to_s, missing: missing }
      )
    end
  end

  class ExternalApiNotImplementedError < Error
    def initialize(operation)
      super(
        "External request is prepared, but no Provider SDK or HTTP call is implemented",
        code: "external_api_not_implemented",
        details: { operation: operation.to_s }
      )
    end
  end

  class SafetyIndeterminateError < Error
    def initialize
      super(
        "Safety classification was indeterminate; normal selection was stopped",
        code: "safety_indeterminate"
      )
    end
  end
end
