# frozen_string_literal: true

require_relative "test_helper"

class Bv2IntegratedEvaluatorTest < Minitest::Test
  def test_integrated_judgments_are_unique_and_follow_the_frozen_rubric
    path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_integrated_codex_judgments_v1.csv")
    rows = CSV.read(path, headers: true, encoding: "UTF-8")

    assert_equal rows.length, rows.map { |row| row.fetch("pair_id") }.uniq.length
    rows.each do |row|
      acceptable = row.fetch("acceptable") == "true"
      if acceptable
        assert_equal "just_right", row.fetch("distance")
        assert_includes %w[same_domain analogical_transfer], row.fetch("relation_type")
      else
        assert_includes %w[too_close too_far not_obserbing], row.fetch("distance")
        assert_includes %w[direct_restatement weak_connection unrelated], row.fetch("relation_type")
      end
    end
  end

  def test_committed_integrated_evaluation_is_complete_and_recomputed
    path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_integrated_evaluation_v1.json")
    result = JSON.parse(File.read(path, encoding: "UTF-8"))
    outcomes_path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_integrated_evaluated_outcomes_v1.jsonl")
    outcomes = File.readlines(outcomes_path, encoding: "UTF-8").map { |line| JSON.parse(line) }

    assert_equal 108, outcomes.length
    assert_equal outcomes.count { |row| row.fetch("acceptable") }, result.dig("quality", "acceptable_count")
    assert_equal 51, result.dig("quality", "acceptable_count")
    assert_in_delta 51.0 / 108, result.dig("quality", "acceptable_rate"), 0.0001
    assert_equal 8, result.dig("quality", "unresolved_low_confidence_pair_count")
    assert_equal 0, result.fetch("technical_error_count")
    assert_equal 0, result.dig("selection", "realtime_line_evaluation_llm_calls")
  end
end
