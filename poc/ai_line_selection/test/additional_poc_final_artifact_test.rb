# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class AdditionalPocFinalArtifactTest < Minitest::Test
  def setup
    path = File.join(configuration.root_dir, "data", "evaluations", "additional_poc_final_v1.yml")
    @document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
  end

  def test_decision_preserves_fixed_noninferiority_criterion
    comparison = @document.fetch("comparison")

    assert_equal(-26.51, comparison.fetch("blind_acceptable_rate_delta_percentage_points"))
    assert_equal(-7.0, comparison.fetch("noninferiority_minimum_delta_percentage_points"))
    assert_equal false, comparison.fetch("noninferiority_met")
    assert_equal false, comparison.fetch("candidate_absolute_quality_met")
    assert_equal false, comparison.fetch("candidate_fatal_grounding_requirement_met")
  end

  def test_no_current_method_or_provider_is_promoted
    decision = @document.fetch("decision")

    assert_equal "reject_both_current_end_to_end_methods", decision.fetch("option")
    assert_equal false, decision.fetch("production_method_selected")
    assert_equal false, decision.fetch("provider_selected")
    assert_equal false, decision.fetch("model_selected")
    assert_equal true, decision.fetch("epic_can_close")
  end

  def test_epic_cost_stays_within_fixed_limit
    cost = @document.fetch("cost")

    assert_equal true, cost.fetch("within_limit")
    assert_operator cost.fetch("epic_actual_external_api_cost_jpy"), :<, cost.fetch("epic_limit_jpy")
    assert_equal 0.0, cost.fetch("issue_25_failed_live_attempt_cost_jpy")
  end
end
