# frozen_string_literal: true

require_relative "test_helper"

class Bv2VsBv1ComparisonTest < Minitest::Test
  def test_recomputes_gate_a_inputs_from_saved_artifacts_without_api
    result = AiLineSelection::Bv2VsBv1Comparison.new(configuration: configuration).call

    assert_equal 0, result.fetch(:external_api_calls)
    assert_equal 54, result.dig(:b1, "acceptable_count")
    assert_equal 51, result.dig(:b2, "acceptable_count")
    assert_equal(-2.78, result.dig(:deltas, "acceptable_percentage_points"))
    assert_equal 29, result.dig(:b1, "direct_restatement_too_close_count")
    assert_equal 19, result.dig(:b2, "direct_restatement_too_close_count")
    assert_equal 35, result.dig(:b2, "too_far_plus_unrelated_count")
    assert_equal 31, result.dig(:b2, "acceptable_analogical_transfer_count")
    assert_equal 10, result.dig(:b1, "all_three_repetitions_acceptable_entry_count")
    assert_equal 4, result.dig(:b2, "all_three_repetitions_acceptable_entry_count")
    assert_equal false, result.dig(:comparison_scope, :simultaneous_head_to_head)
    assert_equal true, result.fetch(:gate_b_not_evaluated)
  end
end
