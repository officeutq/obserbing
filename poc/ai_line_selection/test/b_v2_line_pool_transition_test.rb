# frozen_string_literal: true

require_relative "test_helper"

class Bv2LinePoolTransitionTest < Minitest::Test
  def test_rejected_gate_a_does_not_open_line_pool_improvement
    result = AiLineSelection::Bv2LinePoolTransition.new(configuration: configuration).call

    assert_equal "architecture_rejected", result.dig(:gate_a, :outcome)
    assert_equal false, result.dig(:transition, :line_pool_improvement_epic_allowed)
    assert_equal false, result.dig(:transition, :line_pool_improvement_epic_created)
    assert_equal false, result.dig(:transition, :gate_b_activated)
    assert_equal "rejected_experiment_not_gate_b_baseline", result.dig(:tested_configuration_snapshot, :status)
    assert_equal 96, result.dig(:tested_configuration_snapshot, :approved_line_count)
    assert_match(/\A[0-9a-f]{64}\z/, result.dig(:tested_configuration_snapshot, :approved_line_canonical_sha256))
    assert_equal true, result.dig(:future_selection_poc, :required_before_any_line_pool_improvement_epic)
    assert_equal false, result.dig(:future_selection_poc, :human_review_blocks_this_transition_decision)
    assert_equal false, result.fetch(:production_adoption_decided)
    assert_equal false, result.fetch(:line_pool_modified)
    assert_equal 0, result.fetch(:external_api_calls)
  end
end
