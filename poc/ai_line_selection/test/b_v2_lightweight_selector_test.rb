# frozen_string_literal: true

require_relative "test_helper"

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
end
