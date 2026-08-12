# frozen_string_literal: true

module AiLineSelection
  Usage = Data.define(
    :input_units,
    :output_units,
    :cached_input_units,
    :estimated_cost_usd,
    :estimated_cost_jpy
  ) do
    def to_h
      {
        input_units: input_units,
        output_units: output_units,
        cached_input_units: cached_input_units,
        estimated_cost_usd: estimated_cost_usd,
        estimated_cost_jpy: estimated_cost_jpy
      }
    end

    def self.zero
      new(
        input_units: 0,
        output_units: 0,
        cached_input_units: 0,
        estimated_cost_usd: 0.0,
        estimated_cost_jpy: 0.0
      )
    end
  end

  AdapterResponse = Data.define(:data, :provider, :model, :request_id, :usage)

  PreparedRequest = Data.define(
    :operation,
    :provider,
    :model,
    :prompt_version,
    :schema_version,
    :prompt,
    :response_schema,
    :input,
    :fixture_context,
    :timeout_seconds,
    :settings
  )

  Invocation = Data.define(:value, :metadata)

  HttpResponse = Data.define(:status, :headers, :body)
end
