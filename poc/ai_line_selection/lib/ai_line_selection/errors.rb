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

  class AuthenticationError < Error
    def initialize(provider, request_id: nil)
      super(
        "External AI authentication failed",
        code: "authentication_error",
        details: { provider: provider, request_id: request_id }.compact
      )
    end
  end

  class RateLimitError < Error
    def initialize(provider, request_id: nil, retry_after: nil)
      super(
        "External AI rate limit was reached",
        code: "rate_limit_error",
        retryable: true,
        details: { provider: provider, request_id: request_id, retry_after: retry_after }.compact
      )
    end
  end

  class ProviderServerError < Error
    def initialize(provider, status:, request_id: nil)
      super(
        "External AI provider returned a server error",
        code: "provider_server_error",
        retryable: true,
        details: { provider: provider, status: status, request_id: request_id }.compact
      )
    end
  end

  class ProviderHttpError < Error
    def initialize(provider, status:, request_id: nil)
      super(
        "External AI provider returned an HTTP error",
        code: "provider_http_error",
        details: { provider: provider, status: status, request_id: request_id }.compact
      )
    end
  end

  class ProviderTimeoutError < Error
    def initialize(provider)
      super(
        "External AI request timed out",
        code: "provider_timeout_error",
        retryable: true,
        details: { provider: provider }
      )
    end
  end

  class ProviderNetworkError < Error
    def initialize(provider, error_class:)
      super(
        "External AI network request failed",
        code: "provider_network_error",
        retryable: true,
        details: { provider: provider, error_class: error_class }
      )
    end
  end

  class ResponseParseError < Error
    def initialize(provider, request_id: nil, usage: nil)
      super(
        "External AI response was not valid JSON",
        code: "response_parse_error",
        retryable: true,
        details: { provider: provider, request_id: request_id, usage: usage }.compact
      )
    end
  end

  class IncompleteResponseError < Error
    def initialize(provider, request_id: nil, reason: nil, usage: nil)
      super(
        "External AI response was incomplete",
        code: "incomplete_response_error",
        retryable: true,
        details: { provider: provider, request_id: request_id, reason: reason, usage: usage }.compact
      )
    end
  end

  class ProviderRefusalError < Error
    def initialize(provider, request_id: nil)
      super(
        "External AI provider refused the request",
        code: "provider_refusal_error",
        details: { provider: provider, request_id: request_id }.compact
      )
    end
  end

  class BudgetExceededError < Error
    def initialize(estimated_cost_jpy:, limit_jpy:)
      super(
        "External AI PoC budget limit would be exceeded",
        code: "budget_exceeded_error",
        details: { estimated_cost_jpy: estimated_cost_jpy, limit_jpy: limit_jpy }
      )
    end
  end

  class CostAnomalyError < Error
    def initialize(provider, observed_cost_jpy:, expected_max_cost_jpy:)
      super(
        "External AI cost exceeded the per-request safety estimate",
        code: "cost_anomaly_error",
        details: {
          provider: provider,
          observed_cost_jpy: observed_cost_jpy,
          expected_max_cost_jpy: expected_max_cost_jpy
        }
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
