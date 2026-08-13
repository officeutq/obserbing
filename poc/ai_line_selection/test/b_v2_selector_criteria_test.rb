# frozen_string_literal: true

require "digest"
require "yaml"
require_relative "test_helper"

class Bv2SelectorCriteriaTest < Minitest::Test
  def test_issue_45_freezes_uniform_selector_and_recalculates_result_hash
    criteria = YAML.safe_load_file(
      File.join(configuration.root_dir, "data", "evaluations", "b_v2_selector_criteria_v1.yml"),
      permitted_classes: [], aliases: false
    )
    result_path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_selector_comparison_v1.json")
    result = JSON.parse(File.read(result_path, encoding: "UTF-8"))

    assert_equal "frozen_before_issue_46_live_results", criteria.fetch("status")
    assert_equal "uniform", criteria.dig("selector", "strategy")
    assert_equal "b-v2-selector-v1", criteria.dig("selector", "version")
    assert_equal 0, criteria.dig("selector", "realtime_line_evaluation_llm_calls")
    assert_equal 1.0, criteria.dig("offline_result", "common_results", "reproducibility_rate")
    assert_equal 0, criteria.dig("offline_result", "common_results", "rule_violation_count")
    assert_equal Digest::SHA256.hexdigest(JSON.generate(result)),
                 criteria.dig("offline_result", "source_canonical_json_sha256")
  end
end
