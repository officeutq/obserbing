# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "json"
require "yaml"

class Bv2LightweightSelectorTest < Minitest::Test
  def setup
    @candidates = [
      { "line_id" => "L001", "abstraction_similarity" => 0.44, "surface_similarity" => 0.39, "domain_primary" => "choice" },
      { "line_id" => "L002", "abstraction_similarity" => 0.51, "surface_similarity" => 0.31, "domain_primary" => "choice" },
      { "line_id" => "L003", "abstraction_similarity" => 0.58, "surface_similarity" => 0.22, "domain_primary" => "change" }
    ]
  end

  def test_all_fixed_strategies_are_reproducible_and_bounded
    AiLineSelection::Bv2LightweightSelector::STRATEGIES.each do |strategy|
      selector = AiLineSelection::Bv2LightweightSelector.new(strategy: strategy, a_min: 0.425, s_max: 0.425)
      first = selector.select(candidates: @candidates, seed: 12_345)
      second = selector.select(candidates: @candidates, seed: 12_345)
      weights = selector.candidate_weights(candidates: @candidates).values

      assert_equal first, second, strategy
      assert_operator weights.min, :>=, 0.75, strategy
      assert_operator weights.max, :<=, 1.25, strategy
      assert_operator weights.max / weights.min, :<=, 1.666667, strategy
    end
  end

  def test_quality_labels_are_rejected_as_selector_features
    selector = AiLineSelection::Bv2LightweightSelector.new(strategy: "uniform", a_min: 0.425, s_max: 0.425)
    error = assert_raises(AiLineSelection::DataError) do
      selector.select(candidates: [@candidates.first.merge("acceptable" => true)], seed: 1)
    end

    assert_includes error.details.fetch(:prohibited_keys), "acceptable"
  end

  def test_empty_candidates_return_semantic_silence
    selector = AiLineSelection::Bv2LightweightSelector.new(strategy: "rank_fusion", a_min: 0.425, s_max: 0.425)
    result = selector.select(candidates: [], seed: 1)

    assert_equal "silence", result.fetch(:status)
    assert_nil result.fetch(:line_id)
    assert_equal "no_eligible_candidate", result.fetch(:silence_reason)
  end

  def test_preflight_verifies_frozen_sources_without_quality_aggregation
    plan = AiLineSelection::Bv2LightweightSelectorComparison.new(configuration: configuration).plan

    assert_equal 61, plan.fetch(:issue)
    assert_equal false, plan.fetch(:network_call_performed)
    assert_equal 0, plan.fetch(:external_api_calls)
    assert_equal false, plan.fetch(:quality_aggregation_performed)
    assert_equal 10_368, plan.fetch(:pair_count)
    assert_equal 108, plan.fetch(:outcome_slots)
    assert_equal 96, plan.fetch(:line_count)
    assert_equal AiLineSelection::Bv2LightweightSelector::STRATEGIES, plan.fetch(:selectors)
    assert_equal "evaluation_only", plan.fetch(:label_usage)
    assert_equal true, plan.fetch(:ready_for_offline_comparison)
  end

  def test_saved_mechanical_comparison_reproduces_uniform_without_label_features
    manifest = JSON.parse(File.read(artifact("b_v2_lightweight_selector_manifest_v1.json"), encoding: "UTF-8"))
    selections = CSV.read(artifact("b_v2_lightweight_selector_selections_v1.csv"), headers: true, encoding: "UTF-8")

    assert_equal 1296, selections.length
    assert_equal true, manifest.dig("uniform_reproduction", "primary", "exact")
    assert_equal true, manifest.dig("uniform_reproduction", "neighbor", "exact")
    assert_equal false, manifest.fetch("selector_input_includes_quality_labels")
    assert_equal 0, manifest.dig("new_pair_review", "new_codex_provisional_review_required_count")
    assert selections.all? { |row| row.fetch("reproducible") == "true" }
    ratios = selections.filter_map do |row|
      value = row.fetch("maximum_weight_ratio")
      Float(value) unless value.to_s.empty?
    end
    assert_operator ratios.max, :<=, 1.666667
  end

  def test_saved_quality_comparison_preserves_baseline_and_freezes_insufficient_gain
    result = JSON.parse(File.read(artifact("b_v2_lightweight_selector_comparison_v1.json"), encoding: "UTF-8"))
    primary = result.fetch("summaries").select { |row| row.fetch("band") == "primary" }.to_h { |row| [row.fetch("selector"), row] }
    neighbor = result.fetch("summaries").select { |row| row.fetch("band") == "neighbor" }.to_h { |row| [row.fetch("selector"), row] }

    assert_equal 1.0, result.fetch("selected_pair_label_coverage_rate")
    assert_equal false, result.fetch("selector_input_includes_quality_labels")
    assert_equal 0, result.fetch("external_api_calls")
    assert_equal 69, primary.fetch("uniform").fetch("acceptable_count")
    assert_equal 31, primary.fetch("uniform").dig("known_acceptable_opportunity", "missed_known_acceptable_count")
    assert_equal 70, primary.fetch("bounded_domain_diversity").fetch("acceptable_count")
    assert_equal 30, primary.fetch("bounded_domain_diversity").dig("known_acceptable_opportunity", "missed_known_acceptable_count")
    assert_equal 69, neighbor.fetch("bounded_domain_diversity").fetch("acceptable_count")
    assert_equal 28, neighbor.fetch("bounded_domain_diversity").dig("known_acceptable_opportunity", "missed_known_acceptable_count")
    assert result.fetch("summaries").all? { |row| row.fetch("seed_reproducibility_rate") == 1.0 }
    assert_equal "selector_gain_insufficient", result.dig("diagnosis", "value")
    assert_equal false, result.fetch("changes_existing_gate_a_or_epic_40_decision")
  end

  def test_cross_validation_and_low_confidence_sensitivity_are_explicit
    result = JSON.parse(File.read(artifact("b_v2_lightweight_selector_comparison_v1.json"), encoding: "UTF-8"))
    cross_validation = result.fetch("cross_validation")

    assert_equal 6, cross_validation.fetch("folds").length
    assert_equal 2, cross_validation.fetch("primary_holdout_folds_with_positive_acceptable_gain")
    assert_equal 5, cross_validation.fetch("primary_holdout_folds_with_nonworse_missed_count")
    assert_equal false, cross_validation.fetch("generalization_proven")
    assert_equal 0, result.dig("low_confidence_sensitivity", "primary", "acceptable_gain_count")
    assert_equal false, result.dig("low_confidence_sensitivity", "primary", "gain_positive")
    assert_equal true, result.dig("robustness", "same_winner")
  end

  def test_blind_packet_contains_only_blind_fields_and_all_available_disagreements
    packet = CSV.read(artifact("b_v2_lightweight_selector_blind_human_review_v1.csv"), headers: true, encoding: "UTF-8")
    mapping = YAML.safe_load_file(artifact("b_v2_lightweight_selector_blind_mapping_v1.yml"), permitted_classes: [], aliases: false)

    assert_equal 17, packet.length
    assert_equal 17, mapping.fetch("cases").length
    forbidden_headers = %w[selector line_id similarity codex_judgment existing_label]
    forbidden_headers.each do |header|
      refute packet.headers.any? { |value| value.include?(header) }, header
    end
    assert packet.all? { |row| !row.fetch("entry_text").empty? && !row.fetch("option_a_text").empty? && !row.fetch("option_b_text").empty? }
    assert_equal true, mapping.fetch("do_not_distribute_with_blind_packet")
  end

  private

  def artifact(filename)
    File.expand_path("../data/evaluations/b_v2_lightweight_selector_v1/#{filename}", __dir__)
  end
end
