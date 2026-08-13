# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class SafetyBoundaryComparisonTest < Minitest::Test
  def test_additional_dataset_has_fixed_categories_and_expectations
    comparison = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "additional-v1",
      dataset: "additional"
    )

    assert_equal 24, comparison.cases.length
    assert_equal 24, comparison.cases.map { |item| item.fetch("id") }.uniq.length
    assert_equal({ "normal" => 17, "indeterminate" => 4, "safety" => 3 },
                 comparison.cases.map { |item| item.dig("expected", "safety") }.tally)
    assert comparison.cases.all? { |item| item.fetch("source_set") == "additional-v1" }
  end

  def test_candidate_full_keeps_initial_and_additional_sets_separate
    comparison = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "additional-v1",
      dataset: "candidate-full"
    )

    assert_equal 72, comparison.cases.length
    assert_equal({ "initial_entries" => 36, "initial_safety" => 12, "additional-v1" => 24 },
                 comparison.cases.map { |item| item.fetch("source_set") }.tally)
  end

  def test_fixture_uses_additional_schema_and_never_routes_non_normal_to_meaning
    Dir.mktmpdir do |directory|
      report = AiLineSelection::SafetyBoundaryComparison.new(
        configuration: configuration,
        boundary: "additional-v1",
        dataset: "additional"
      ).call(
        providers: ["fixture"],
        repetitions: 3,
        output_dir: directory
      )

      provider = report.dig(:providers, "fixture")
      assert_equal 72, provider.fetch(:executions)
      assert_equal 1.0, provider.fetch(:classification_accuracy)
      assert_empty provider.fetch(:unsafe_normal_flow_case_ids)
      assert_equal 1.0, provider.dig(:exact_classification_and_reason_stability, :rate)
      assert provider.fetch(:category_accuracy).values.all? { |item| item.fetch(:accuracy) == 1.0 }

      records = File.readlines(File.join(directory, "provider_outputs.jsonl"), encoding: "UTF-8").map do |line|
        JSON.parse(line)
      end
      refute(records.any? do |record|
        record.fetch("actual_classification") != "normal" && record.dig("route", "normal_flow_allowed")
      end)
    end
  end

  def test_plan_is_offline_and_enforces_boundary_request_cap
    report = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "additional-v1",
      dataset: "candidate-full"
    ).plan(providers: ["openai"], repetitions: 3)

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 216, report.fetch(:total_requests)
    assert_equal 432, report.fetch(:maximum_requests_with_retries)
    assert_operator report.fetch(:maximum_cost_with_one_retry_jpy), :<, 5_000
  end

  def test_draft_boundary_can_run_against_the_same_additional_dataset
    report = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "draft-1",
      dataset: "additional"
    ).plan(providers: ["openai"], repetitions: 3)

    assert_equal 24, report.fetch(:case_count)
    assert_equal 72, report.fetch(:total_requests)
  end

  def test_additional_v2_is_versioned_independently
    report = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "additional-v2",
      dataset: "candidate-full"
    ).plan(providers: ["openai"], repetitions: 3)

    assert_equal "safety_boundary_additional_v2_candidate_full", report.fetch(:operation)
    assert_equal 216, report.fetch(:total_requests)
  end

  def test_additional_v3_is_versioned_independently
    report = AiLineSelection::SafetyBoundaryComparison.new(
      configuration: configuration,
      boundary: "additional-v3",
      dataset: "candidate-full"
    ).plan(providers: ["openai"], repetitions: 3)

    assert_equal "safety_boundary_additional_v3_candidate_full", report.fetch(:operation)
    assert_equal 216, report.fetch(:total_requests)
  end
end
