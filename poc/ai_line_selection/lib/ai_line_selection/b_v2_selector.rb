# frozen_string_literal: true

require "digest"

module AiLineSelection
  class Bv2Selector
    VERSION = "b-v2-selector-v1"
    STRATEGIES = %w[uniform abstraction_weighted bounded_domain_diversity].freeze
    A_MIN = 0.45
    SIMILARITY_WEIGHT_FLOOR = 0.75
    DOMAIN_WEIGHT_MAXIMUM = 1.20

    def self.seed(base_seed:, entry_id:, repetition:)
      Digest::SHA256.hexdigest("#{base_seed}|#{entry_id}|#{Integer(repetition)}")[0, 16].to_i(16)
    end

    def initialize(strategy:)
      @strategy = strategy.to_s
      unless STRATEGIES.include?(@strategy)
        raise ConfigurationError.new("Unknown B-v2 selector strategy", details: { strategy: @strategy })
      end
    end

    def select(candidates:, seed:)
      rows = Array(candidates).sort_by { |candidate| candidate.fetch("line_id") }
      return silence if rows.empty?

      weights = weights_for(rows)
      random = Random.new(Integer(seed))
      point = random.rand * weights.sum
      cumulative = 0.0
      selected_index = weights.each_index.find do |index|
        cumulative += weights.fetch(index)
        point < cumulative
      end || weights.length - 1
      selected = rows.fetch(selected_index)
      {
        status: "line",
        line_id: selected.fetch("line_id"),
        strategy: @strategy,
        selector_version: VERSION,
        seed: Integer(seed),
        candidate_count: rows.length,
        selected_weight: weights.fetch(selected_index).round(8),
        silence_reason: nil
      }
    end

    private

    def weights_for(rows)
      return Array.new(rows.length, 1.0) if @strategy == "uniform"

      base = rows.map do |candidate|
        normalized = ((candidate.fetch("abstraction_similarity").to_f - A_MIN) / (1.0 - A_MIN)).clamp(0.0, 1.0)
        SIMILARITY_WEIGHT_FLOOR + ((1.0 - SIMILARITY_WEIGHT_FLOOR) * normalized)
      end
      return base if @strategy == "abstraction_weighted"

      counts = rows.map { |candidate| neutral_domain(candidate["domain_primary"]) }.compact.tally
      maximum = counts.values.max.to_f
      base.each_with_index.map do |weight, index|
        domain = neutral_domain(rows.fetch(index)["domain_primary"])
        multiplier = if domain.nil? || maximum.zero?
                       1.0
                     else
                       [1.0 + (0.10 * ((maximum / counts.fetch(domain)) - 1.0)), DOMAIN_WEIGHT_MAXIMUM].min
                     end
        weight * multiplier
      end
    end

    def neutral_domain(value)
      name = value.to_s
      return nil if name.empty? || %w[unknown other].include?(name)
      name
    end

    def silence
      {
        status: "silence",
        line_id: nil,
        strategy: @strategy,
        selector_version: VERSION,
        seed: nil,
        candidate_count: 0,
        selected_weight: nil,
        silence_reason: "no_eligible_candidate"
      }
    end
  end
end
