# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class Bv2ProfileEvaluationTest < Minitest::Test
  def test_tracked_smoke_artifacts_match_issue_42_limits_and_decision
    result = YAML.safe_load_file(
      File.join(configuration.root_dir, "data", "evaluations", "b_v2_profile_smoke_v1.yml"),
      permitted_classes: [], aliases: false
    )
    outputs = File.readlines(
      File.join(configuration.root_dir, "data", "evaluations", "b_v2_profile_smoke_outputs_v1.jsonl"),
      chomp: true
    ).map { |line| JSON.parse(line) }

    assert_equal 60, outputs.length
    assert_equal 10, outputs.map { |row| row.fetch("item_id") }.uniq.length
    assert_equal 3, outputs.map { |row| row.fetch("repetition") }.uniq.length
    assert_equal 2, outputs.map { |row| row.fetch("version") }.uniq.length
    assert_equal outputs.sum { |row| row.dig("usage", "input_units") + row.dig("usage", "output_units") },
                 result.dig("execution", "total_input_and_output_tokens")
    assert_in_delta outputs.sum { |row| row.dig("usage", "estimated_cost_jpy") },
                    result.dig("execution", "total_estimated_cost_jpy"), 0.0001
    assert_operator result.dig("execution", "provider_requests"), :<=, 120
    assert_operator result.dig("execution", "total_input_and_output_tokens"), :<=, 50_000
    assert_operator result.dig("execution", "total_estimated_cost_jpy"), :<=, 500.0
    assert_equal "b-v2-profile-primary-secondary-v1", result.dig("decision", "selected_for_issue_43")
    assert_equal 0, result.dig("external_api", "embedding_api_requests")
  end
end
