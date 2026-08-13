# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class AbstractionOnlyIntegratedLiveArtifactTest < Minitest::Test
  def setup
    path = File.join(configuration.root_dir, "data", "evaluations", "abstraction_only_integrated_live_v1.yml")
    @document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
  end

  def test_live_run_completed_with_all_external_usage_counted
    execution = @document.fetch("execution")

    assert_equal true, execution.fetch("completed")
    assert_equal 108, execution.fetch("normal_flow_record_count")
    assert_equal 361, execution.fetch("logical_completed_request_count")
    assert_equal 362, execution.fetch("successful_external_request_count")
    assert_equal 1, execution.fetch("resumed_orphan_request_count")
    assert_equal 0, execution.fetch("external_retry_count")
  end

  def test_critical_review_does_not_hide_fatal_failure
    quality = @document.dig("results", "blind_quality_after_critical_review")

    assert_equal 108, quality.fetch("evaluated_count")
    assert_equal 80, quality.fetch("acceptable_count")
    assert_equal 0.7407, quality.fetch("acceptable_rate")
    assert_equal 1, quality.fetch("fatal_grounding_mismatch_count")
    assert_empty quality.fetch("low_confidence_entry_ids")
  end

  def test_fixed_criteria_keep_live_chain_rejected
    acceptance = @document.fetch("acceptance")

    assert_equal true, acceptance.fetch("existing_normal_overblock_met")
    assert_equal true, acceptance.fetch("end_to_end_p95_met")
    assert_equal true, acceptance.fetch("cost_per_post_met")
    assert_equal false, acceptance.fetch("candidate_top20_jaccard_met")
    assert_equal false, acceptance.fetch("displayed_line_acceptable_rate_met")
    assert_equal false, acceptance.fetch("fatal_grounding_mismatch_met")
    assert_equal false, acceptance.fetch("all_required_criteria_met")
    assert_equal true, @document.dig("decision", "previous_rejection_confirmed")
  end

  def test_live_cost_is_within_epic_limit
    cost = @document.fetch("api_and_cost")

    assert_equal 88.1341, cost.fetch("actual_estimated_cost_jpy")
    assert_equal 636.0074, cost.fetch("epic_cumulative_after_issue_jpy")
    assert_equal true, cost.fetch("within_epic_limit")
    assert_operator cost.fetch("epic_cumulative_after_issue_jpy"), :<, cost.fetch("epic_limit_jpy")
  end
end
