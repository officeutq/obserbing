# frozen_string_literal: true

require_relative "test_helper"

class Bv2GateAEvaluatorTest < Minitest::Test
  def test_applies_frozen_gate_a_and_derives_rejection
    result = AiLineSelection::Bv2GateAEvaluator.new(configuration: configuration).call
    by_id = result.fetch(:candidate_conditions).to_h { |condition| [condition.fetch(:id), condition] }
    floors = result.fetch(:rejection_floors).to_h { |floor| [floor.fetch(:id), floor] }

    assert_equal "b-v2-pre-evaluation-criteria-v2", result.fetch(:criteria_id)
    assert_equal "36c790098bef202a44e10ae6cdc175785b6c3427668868e93f628f0d6e684648", result.fetch(:criteria_sha256)
    assert_equal false, by_id.fetch("acceptable_rate").fetch(:pass)
    assert_equal true, by_id.fetch("too_close_reduction_rate").fetch(:pass)
    assert_equal false, by_id.fetch("too_far_plus_unrelated_count").fetch(:pass)
    assert_equal false, by_id.fetch("acceptable_analogical_count").fetch(:pass)
    assert_equal false, by_id.fetch("all_three_acceptable_entry_count").fetch(:pass)
    assert_equal true, by_id.fetch("semantic_silence_count").fetch(:pass)
    assert_equal false, by_id.fetch("unresolved_low_confidence_count").fetch(:pass)
    assert_equal false, by_id.fetch("end_to_end_p95_seconds").fetch(:pass)
    assert_equal true, floors.fetch("acceptable_improvement_below_floor").fetch(:triggered)
    assert_equal true, floors.fetch("operational_budget_violation_on_valid_run").fetch(:triggered)
    assert_equal "architecture_rejected", result.fetch(:outcome)
    assert_equal 44, result.dig(:low_confidence_sensitivity, :minimum_acceptable_count)
    assert_equal 52, result.dig(:low_confidence_sensitivity, :maximum_acceptable_count)
    assert_equal false, result.dig(:low_confidence_sensitivity, :can_change_gate_a_outcome)
    assert_equal false, result.fetch(:production_adoption_decided)
    assert_equal 0, result.fetch(:external_api_calls)
  end
end
