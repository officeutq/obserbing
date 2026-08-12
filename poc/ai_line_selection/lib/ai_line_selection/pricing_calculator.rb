# frozen_string_literal: true

module AiLineSelection
  class PricingCalculator
    MILLION = 1_000_000.0

    def initialize(settings:, usd_to_jpy:)
      @pricing = settings.fetch("pricing")
      @usd_to_jpy = usd_to_jpy.to_f
    end

    def usage(input_units:, output_units:, cached_input_units: 0)
      input_units = input_units.to_i
      output_units = output_units.to_i
      cached_input_units = [cached_input_units.to_i, input_units].min
      regular_input_units = input_units - cached_input_units
      usd = (
        regular_input_units * @pricing.fetch("input_per_million_usd").to_f +
        cached_input_units * @pricing.fetch("cached_input_per_million_usd").to_f +
        output_units * @pricing.fetch("output_per_million_usd").to_f
      ) / MILLION

      Usage.new(
        input_units: input_units,
        output_units: output_units,
        cached_input_units: cached_input_units,
        estimated_cost_usd: usd.round(8),
        estimated_cost_jpy: (usd * @usd_to_jpy).round(4)
      )
    end
  end
end
