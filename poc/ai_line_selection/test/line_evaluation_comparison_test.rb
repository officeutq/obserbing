# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class LineEvaluationComparisonTest < Minitest::Test
  def test_external_plan_is_network_free_and_bounded
    report = AiLineSelection::LineEvaluationComparison.new(configuration: configuration).plan(
      providers: %w[openai anthropic],
      repetitions: 3
    )

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 218, report.fetch(:total_requests)
    assert_equal 436, report.fetch(:maximum_requests_with_retries)
    assert_operator report.fetch(:maximum_cost_with_one_retry_jpy), :<=,
                    report.fetch(:configured_budget_jpy)
    assert_equal true, report.fetch(:external_api_flag_required)
    assert_equal 20, report.fetch(:candidate_limit)
  end

  def test_fixture_comparison_records_ai_rails_and_review_artifacts
    Dir.mktmpdir do |directory|
      report = AiLineSelection::LineEvaluationComparison.new(configuration: configuration).call(
        providers: ["fixture"],
        repetitions: 2,
        entry_ids: %w[E001 E002],
        embedding_provider: "fixture",
        output_dir: directory
      )

      assert_equal true, report.fetch(:completed)
      assert_equal 2, report.fetch(:entry_count)
      assert_equal 4, report.dig(:providers, "fixture", :executions)
      assert report.dig(:providers, "fixture").key?(:ai_rails_same_rate)
      assert report.dig(:providers, "fixture").key?(:threshold_sensitivity)
      assert_equal true, report.fetch(:technical_errors_are_not_silence)
      assert_equal 2, File.readlines(File.join(directory, "candidate_sets.jsonl")).length
      assert_equal 3, CSV.read(File.join(directory, "human_evaluation.csv")).length
      manifest = JSON.parse(File.read(File.join(directory, "manifest.json"), encoding: "UTF-8"))
      assert_empty manifest.fetch("leaked_line_metadata")
    end
  end

  def test_external_comparison_requires_explicit_flag
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::LineEvaluationComparison.new(configuration: configuration).call(
        providers: ["openai"],
        repetitions: 1,
        entry_ids: ["E001"]
      )
    end

    assert_equal "line_evaluation", error.details.fetch(:operation)
  end
end
