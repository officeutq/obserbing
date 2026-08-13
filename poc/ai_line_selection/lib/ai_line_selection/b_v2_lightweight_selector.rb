# frozen_string_literal: true

module AiLineSelection
  class Bv2LightweightSelector
    VERSION = "b-v2-lightweight-selector-v1"
    STRATEGIES = %w[
      uniform
      abstraction_bounded_weighted
      surface_band_center
      dual_margin_band_center
      rank_fusion
      bounded_domain_diversity
    ].freeze
    MIN_WEIGHT = 0.75
    MAX_WEIGHT = 1.25
    PROHIBITED_KEYS = %w[
      acceptable distance relation_type confidence low_confidence judge reviewer_role
      label_source reason user_fact_assertion explicit_contradiction advice_or_diagnosis
      clearly_unrelated
    ].freeze

    def initialize(strategy:, a_min:, s_max:)
      @strategy = strategy.to_s
      @a_min = Float(a_min)
      @s_max = Float(s_max)
      unless STRATEGIES.include?(@strategy)
        raise ConfigurationError.new("Unknown lightweight selector strategy", details: { strategy: @strategy })
      end
    end

    def select(candidates:, seed:)
      rows = sanitized_candidates(candidates)
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
        minimum_weight: weights.min.round(8),
        maximum_weight: weights.max.round(8),
        maximum_weight_ratio: (weights.max / weights.min).round(8),
        silence_reason: nil
      }
    end

    def candidate_weights(candidates:)
      rows = sanitized_candidates(candidates)
      weights_for(rows).each_with_index.to_h { |weight, index| [rows.fetch(index).fetch("line_id"), weight.round(8)] }
    end

    private

    def sanitized_candidates(candidates)
      rows = Array(candidates)
      forbidden = rows.flat_map { |candidate| candidate.keys.map(&:to_s) & PROHIBITED_KEYS }.uniq.sort
      unless forbidden.empty?
        raise DataError.new("Quality labels must not enter lightweight selector features", details: { prohibited_keys: forbidden })
      end

      rows.map do |candidate|
        value = candidate.transform_keys(&:to_s)
        {
          "line_id" => value.fetch("line_id"),
          "abstraction_similarity" => Float(value.fetch("abstraction_similarity")),
          "surface_similarity" => Float(value.fetch("surface_similarity")),
          "domain_primary" => value.fetch("domain_primary", "other").to_s
        }
      end.sort_by { |candidate| candidate.fetch("line_id") }
    end

    def weights_for(rows)
      return [] if rows.empty?
      return Array.new(rows.length, 1.0) if @strategy == "uniform"

      scores = case @strategy
               when "abstraction_bounded_weighted" then abstraction_scores(rows)
               when "surface_band_center" then surface_center_scores(rows)
               when "dual_margin_band_center" then dual_margin_scores(rows)
               when "rank_fusion" then rank_fusion_scores(rows)
               when "bounded_domain_diversity" then domain_diversity_scores(rows)
               end
      scores.map { |score| bounded_weight(score) }
    end

    def abstraction_scores(rows)
      normalize(rows.map { |row| row.fetch("abstraction_similarity") })
    end

    def surface_center_scores(rows)
      values = rows.map { |row| row.fetch("surface_similarity") }
      minimum = values.min
      target = (minimum + @s_max) / 2.0
      radius = (@s_max - minimum) / 2.0
      return Array.new(rows.length, 0.5) if radius <= 0.0

      values.map { |value| (1.0 - ((value - target).abs / radius)).clamp(0.0, 1.0) }
    end

    def dual_margin_scores(rows)
      abstraction_max = rows.map { |row| row.fetch("abstraction_similarity") }.max
      surface_min = rows.map { |row| row.fetch("surface_similarity") }.min
      rows.map do |row|
        abstraction = margin(row.fetch("abstraction_similarity"), @a_min, abstraction_max)
        surface = margin(@s_max - row.fetch("surface_similarity"), 0.0, @s_max - surface_min)
        abstraction + surface <= 0.0 ? 0.0 : (2.0 * abstraction * surface) / (abstraction + surface)
      end
    end

    def rank_fusion_scores(rows)
      abstraction = percentile_ranks(rows, "abstraction_similarity", descending: true)
      surface = percentile_ranks(rows, "surface_similarity", descending: false)
      rows.map { |row| (0.60 * abstraction.fetch(row.fetch("line_id"))) + (0.40 * surface.fetch(row.fetch("line_id"))) }
    end

    def domain_diversity_scores(rows)
      abstraction = abstraction_scores(rows)
      counts = rows.map { |row| row.fetch("domain_primary") }.tally
      maximum = counts.values.max
      rarity = rows.map do |row|
        count = counts.fetch(row.fetch("domain_primary"))
        maximum <= 1 ? 0.5 : 1.0 - ((count - 1).to_f / (maximum - 1))
      end
      abstraction.each_index.map { |index| (0.80 * abstraction.fetch(index)) + (0.20 * rarity.fetch(index)) }
    end

    def normalize(values)
      minimum, maximum = values.minmax
      return Array.new(values.length, 0.5) if maximum == minimum

      values.map { |value| ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0) }
    end

    def margin(value, minimum, maximum)
      return 0.5 if maximum == minimum
      ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0)
    end

    def percentile_ranks(rows, field, descending:)
      ordered = rows.sort_by do |row|
        value = row.fetch(field)
        [descending ? -value : value, row.fetch("line_id")]
      end
      return { ordered.first.fetch("line_id") => 0.5 } if ordered.length == 1

      ordered.each_with_index.to_h do |row, index|
        [row.fetch("line_id"), 1.0 - (index.to_f / (ordered.length - 1))]
      end
    end

    def bounded_weight(score)
      (MIN_WEIGHT + ((MAX_WEIGHT - MIN_WEIGHT) * Float(score).clamp(0.0, 1.0))).clamp(MIN_WEIGHT, MAX_WEIGHT)
    end

    def silence
      {
        status: "silence", line_id: nil, strategy: @strategy,
        selector_version: VERSION, seed: nil, candidate_count: 0,
        selected_weight: nil, minimum_weight: nil, maximum_weight: nil,
        maximum_weight_ratio: nil, silence_reason: "no_eligible_candidate"
      }
    end
  end
end
