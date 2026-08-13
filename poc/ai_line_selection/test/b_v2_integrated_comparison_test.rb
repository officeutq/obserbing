# frozen_string_literal: true

require_relative "test_helper"

class Bv2IntegratedComparisonTest < Minitest::Test
  def test_plan_matches_preflight_and_hard_budgets_without_network
    plan = AiLineSelection::Bv2IntegratedComparison.new(configuration: configuration).plan

    assert_equal false, plan.fetch(:network_call_performed)
    assert_equal 36, plan.fetch(:entry_count)
    assert_equal 96, plan.fetch(:line_count)
    assert_equal 108, plan.fetch(:outcome_slots)
    assert_equal 97, plan.fetch(:line_precompute_requests)
    assert_equal 324, plan.fetch(:post_requests)
    assert_equal 421, plan.fetch(:normal_requests)
    assert_equal 842, plan.fetch(:maximum_requests_with_retries)
    assert_equal 500_000, plan.fetch(:maximum_total_tokens)
    assert_equal 1_500.0, plan.fetch(:issue_budget_jpy)
    assert_equal 2_000.0, plan.fetch(:epic_budget_jpy)
    assert_equal true, plan.fetch(:within_issue_budget)
    assert_equal true, plan.fetch(:within_epic_budget)
    assert_equal 0, plan.fetch(:realtime_line_evaluation_llm_calls)
  end

  def test_external_run_requires_explicit_permission_before_creating_output
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::Bv2IntegratedComparison.new(configuration: configuration).call(
        output_dir: File.join(configuration.path(:results), "should_not_exist_b_v2")
      )
    end
    assert_equal "external_api_disabled", error.code
  end
end
