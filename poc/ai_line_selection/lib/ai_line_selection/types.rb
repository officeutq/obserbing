# frozen_string_literal: true

module AiLineSelection
  Usage = Data.define(:input_units, :output_units, :estimated_cost_jpy) do
    def to_h
      {
        input_units: input_units,
        output_units: output_units,
        estimated_cost_jpy: estimated_cost_jpy
      }
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
    :timeout_seconds
  )

  Invocation = Data.define(:value, :metadata)
end
