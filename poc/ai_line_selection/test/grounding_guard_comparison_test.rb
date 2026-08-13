# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class GroundingGuardComparisonTest < Minitest::Test
  def test_pair_dataset_covers_each_guard_category_with_positive_and_negative_cases
    comparison = AiLineSelection::GroundingGuardComparison.new(configuration: configuration)

    assert_equal 12, comparison.cases.length
    assert_equal AiLineSelection::GroundingGuard::CATEGORIES.sort,
                 comparison.cases.map { |item| item.fetch("category") }.uniq.sort
    comparison.cases.group_by { |item| item.fetch("category") }.each_value do |rows|
      assert_equal %w[negative positive], rows.map { |item| item.fetch("polarity") }.sort
    end
  end

  def test_combined_guard_rejects_required_regressions_and_accepts_matching_pairs
    guard = AiLineSelection::GroundingGuard.new(
      attributes_path: File.join(configuration.root_dir, "data", "grounding_attributes.yml")
    )
    entries = data_loader.entries.to_h { |entry| [entry.fetch("id"), entry] }
    lines = data_loader.lines.to_h { |line| [line.fetch("id"), line] }

    refute guard.evaluate(entry: entries.fetch("E033"), line: lines.fetch("L102")).fetch(:compatible)
    assert guard.evaluate(entry: entries.fetch("E032"), line: lines.fetch("L102")).fetch(:compatible)
    refute guard.evaluate(entry: entries.fetch("E024"), line: lines.fetch("L077")).fetch(:compatible)
    assert guard.evaluate(entry: entries.fetch("E020"), line: lines.fetch("L077")).fetch(:compatible)
  end

  def test_comparison_is_offline_deterministic_and_keeps_candidates_available
    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::GroundingGuardComparison.new(configuration: configuration)
      report = comparison.call(output_dir: directory)
      selected = report.fetch(:strategy_summaries).fetch("combined_v1")

      assert_equal false, report.fetch(:network_call_performed)
      assert_equal 0, report.fetch(:external_api_calls)
      assert_equal 0, selected.fetch(:false_negative_count)
      assert_equal 0, selected.fetch(:false_exclusion_count)
      assert report.fetch(:selected_strategy_reproducible)
      assert report.dig(:completion, :required_regressions_rejected)
      assert_equal 0, report.dig(:completion, :empty_candidate_sets)
      assert_operator report.dig(:selected_strategy_population, :candidates_after_minimum), :>, 0
      assert File.exist?(File.join(directory, "case_results.jsonl"))
      assert File.exist?(File.join(directory, "population_exclusions.jsonl"))
      assert File.exist?(File.join(directory, "summary.json"))
    end
  end

  def test_unknown_strategy_is_rejected
    guard = AiLineSelection::GroundingGuard.new(
      attributes_path: File.join(configuration.root_dir, "data", "grounding_attributes.yml")
    )

    assert_raises(AiLineSelection::ConfigurationError) do
      guard.evaluate(entry: data_loader.entries.first, line: data_loader.lines.first, strategy: "unknown")
    end
  end
end

