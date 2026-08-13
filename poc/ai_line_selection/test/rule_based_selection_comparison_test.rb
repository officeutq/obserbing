# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class RuleBasedSelectionComparisonTest < Minitest::Test
  def test_snapshot_is_fixed_blind_top_five_without_text_or_reasons
    path = File.join(configuration.root_dir, "data", "evaluations", "ruby_selection_inputs_v1.json")
    snapshot = JSON.parse(File.read(path, encoding: "UTF-8"))

    assert_equal "ruby-selection-input-v1", snapshot.fetch("version")
    assert_equal "abstraction_only_v2", snapshot.fetch("mode")
    assert_equal 36, snapshot.fetch("entries").length
    assert snapshot.fetch("entries").all? { |row| row.fetch("candidates").length == 5 }
    refute_includes File.read(path, encoding: "UTF-8"), "entry_text"
    refute_includes File.read(path, encoding: "UTF-8"), '"reason"'
  end

  def test_plan_is_offline_and_fixes_four_strategies_scenarios_and_seeds
    report = AiLineSelection::RuleBasedSelectionComparison.new(configuration: configuration).plan

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 0, report.fetch(:external_api_calls)
    assert_equal AiLineSelection::RuleBasedSelectionComparison::STRATEGIES, report.fetch(:strategies)
    assert_equal AiLineSelection::RuleBasedSelectionComparison::SCENARIOS, report.fetch(:scenarios)
    assert_equal [2_719_001, 2_719_002, 2_719_003], report.fetch(:seeds)
    assert_equal 2_160, report.fetch(:executions)
  end

  def test_comparison_is_reproducible_and_records_zero_rule_violations
    Dir.mktmpdir do |directory|
      report = AiLineSelection::RuleBasedSelectionComparison.new(configuration: configuration).call(output_dir: directory)

      assert_equal 1.0, report.fetch(:same_seed_reproducibility_rate)
      assert report.fetch(:violations).values.all?(&:zero?)
      assert report.fetch(:strategy_summaries).values.all? { |summary| summary.fetch(:violation_count).zero? }
      assert report.fetch(:strategy_summaries).values.all? { |summary|
        summary.dig(:blind_quality, :fatal_grounding_mismatch_count).zero?
      }
      assert report.fetch(:all_strategies_rejected)
      assert_nil report.fetch(:recommended_strategy)
      assert_equal "similarity_weighted_top_n", report.fetch(:diagnostic_best_strategy)
      assert_operator report.dig(:strategy_summaries, "threshold_uniform", :history_none_silence_rate), :>, 0
      assert File.exist?(File.join(directory, "selections.jsonl"))
      assert File.exist?(File.join(directory, "summary.json"))
    end
  end

  def test_all_candidates_reused_produces_semantic_silence_not_an_error
    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::RuleBasedSelectionComparison.new(configuration: configuration)
      comparison.call(output_dir: directory)
      rows = File.readlines(File.join(directory, "selections.jsonl"), encoding: "UTF-8").map { |line| JSON.parse(line) }
      blocked = rows.select { |row| row.fetch("scenario") == "all_candidates_reused" }

      assert_equal 432, blocked.length
      assert blocked.all? { |row| row.fetch("outcome") == "silence" }
      assert blocked.all? { |row| row.fetch("silence_reason") == "all_candidates_filtered" }
    end
  end
end
