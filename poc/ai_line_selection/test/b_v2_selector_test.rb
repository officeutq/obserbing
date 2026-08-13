# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class Bv2SelectorTest < Minitest::Test
  CANDIDATES = [
    { "line_id" => "L001", "abstraction_similarity" => 0.60, "domain_primary" => "choice" },
    { "line_id" => "L021", "abstraction_similarity" => 0.55, "domain_primary" => "relationship" },
    { "line_id" => "L083", "abstraction_similarity" => 0.50, "domain_primary" => "choice" }
  ].freeze

  def test_every_strategy_is_reproducible_for_same_candidates_and_seed
    AiLineSelection::Bv2Selector::STRATEGIES.each do |strategy|
      selector = AiLineSelection::Bv2Selector.new(strategy: strategy)
      first = selector.select(candidates: CANDIDATES, seed: 1234)
      second = selector.select(candidates: CANDIDATES.reverse, seed: 1234)

      assert_equal first, second
    end
  end

  def test_no_candidate_is_silence
    result = AiLineSelection::Bv2Selector.new(strategy: "uniform").select(candidates: [], seed: 1)

    assert_equal "silence", result.fetch(:status)
    assert_equal "no_eligible_candidate", result.fetch(:silence_reason)
  end

  def test_seed_is_stable_and_repetition_specific
    first = AiLineSelection::Bv2Selector.seed(base_seed: 20260812, entry_id: "E001", repetition: 1)
    repeated = AiLineSelection::Bv2Selector.seed(base_seed: 20260812, entry_id: "E001", repetition: 1)
    next_repetition = AiLineSelection::Bv2Selector.seed(base_seed: 20260812, entry_id: "E001", repetition: 2)

    assert_equal first, repeated
    refute_equal first, next_repetition
  end

  def test_offline_comparison_uses_no_external_api
    source = File.join(configuration.path(:results), "abstraction_embedding_20260813T011138Z_8550")
    skip "saved abstraction artifact unavailable" unless Dir.exist?(source)

    Dir.mktmpdir do |directory|
      result = AiLineSelection::Bv2SelectorComparison.new(
        configuration: configuration,
        abstraction_results_dir: source
      ).call(output_path: File.join(directory, "result.json"))

      assert_equal 0, result.fetch(:external_api_calls)
      assert_equal 0, result.fetch(:realtime_line_evaluation_llm_calls)
      assert_equal 108, result.fetch(:outcome_slots)
      assert result.fetch(:strategies).values.all? { |summary| summary.fetch(:reproducibility_rate) == 1.0 }
      assert result.fetch(:strategies).values.all? { |summary| summary.fetch(:rule_violation_count).zero? }
    end
  end
end
