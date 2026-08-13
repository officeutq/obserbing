# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class BV2DesignCriteriaArtifactTest < Minitest::Test
  def setup
    path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_design_criteria_v1.yml")
    @criteria = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
  end

  def test_band_pass_hypothesis_is_fixed_without_realtime_line_llm
    hypothesis = @criteria.fetch("hypothesis")

    assert_equal "eligibility_lower_bound", hypothesis.fetch("abstraction_similarity_role")
    assert_equal "too_close_exclusion_upper_bound", hypothesis.fetch("surface_similarity_role")
    assert_equal "bounded_selection_and_diversity_assist_only", hypothesis.fetch("domain_role")
    assert_equal "none", hypothesis.fetch("structure_realtime_role")
    assert_equal 0, hypothesis.fetch("realtime_line_evaluation_llm_calls")
    assert_equal false, hypothesis.fetch("select_highest_score_only")
  end

  def test_runtime_external_work_is_bounded_to_three_stages
    pipeline = @criteria.fetch("runtime_pipeline")

    assert_equal %w[safety abstraction_and_domain entry_abstraction_and_raw_text_embedding_batch], pipeline.fetch("normal_external_stages")
    assert_equal 3, pipeline.fetch("normal_external_request_limit")
    assert_equal 2, pipeline.fetch("entry_embedding_inputs_per_request")
    assert_equal 1, pipeline.fetch("realtime_llm_provider_limit")
    assert_equal false, pipeline.fetch("line_side_generation_at_post_time")
    assert_equal false, pipeline.fetch("line_side_embedding_at_post_time")
  end

  def test_domain_cannot_make_an_ineligible_candidate_eligible
    eligibility = @criteria.fetch("eligibility")

    assert_includes eligibility.fetch("required_all"), "abstraction_similarity_at_least_a_min"
    assert_includes eligibility.fetch("required_all"), "surface_similarity_at_most_s_max"
    assert_equal false, eligibility.fetch("domain_mismatch_required")
    assert_equal false, eligibility.fetch("domain_can_override_failed_eligibility")
    assert_equal false, eligibility.fetch("thresholds_auto_relaxed_when_empty")
  end

  def test_reflective_distance_quality_thresholds_are_fixed
    quality = @criteria.fetch("quality")

    assert_equal "reflective-distance-v1", quality.fetch("rubric_id")
    assert_equal 0.80, quality.dig("acceptable_outcome_rate", "required_minimum")
    assert_equal 87, quality.dig("acceptable_outcome_rate", "required_minimum_count_for_108")
    assert_equal 0.90, quality.dig("acceptable_outcome_rate", "target")
    assert_equal 0.60, quality.dig("all_three_repetitions_acceptable_entry_rate", "required_minimum")
    assert_equal 22, quality.dig("all_three_repetitions_acceptable_entry_rate", "required_minimum_count_for_36")
    assert_equal 0, quality.dig("required_zero_counts", "user_fact_assertion")
    assert_equal 0, quality.dig("required_zero_counts", "explicit_contradiction")
    assert_equal 0, quality.dig("required_zero_counts", "advice_or_diagnosis")
    assert_nil quality.fetch("analogical_transfer_minimum_quota")
    assert_equal false, quality.fetch("same_line_repetition_is_success_criterion")
  end

  def test_old_ninety_percent_metric_is_not_claimed_as_identical
    rationale = @criteria.fetch("quality_threshold_rationale")

    assert_equal false, rationale.fetch("old_poc_90_percent_semantically_identical")
    refute_empty rationale.fetch("reason")
  end

  def test_b_v1_comparison_controls_line_pool_without_overclaiming_equivalence
    comparison = @criteria.fetch("comparison")

    assert_equal "abstraction-only-v1-diagnostic", comparison.fetch("baseline_method")
    assert_equal true, comparison.fetch("same_rubric_required")
    assert_equal true, comparison.fetch("same_approved_96_lines_required")
    assert_equal true, comparison.fetch("line_pool_controlled_comparison_allowed")
    assert_equal false, comparison.fetch("strict_head_to_head_equivalence_claim_allowed")
  end

  def test_performance_and_cost_budgets_match_design_request
    assert_equal 6.0, @criteria.dig("performance", "end_to_end_p95_seconds", "required_maximum")
    assert_equal 5.0, @criteria.dig("performance", "end_to_end_p95_seconds", "target_maximum")
    assert_equal 1.0, @criteria.dig("cost", "post_cost_jpy", "required_maximum")
    assert_equal 0.7, @criteria.dig("cost", "post_cost_jpy", "target_maximum")
    assert_equal true, @criteria.dig("cost", "line_precompute_cost_reported_separately")
  end

  def test_guard_redesign_does_not_ban_concrete_analogy_by_itself
    guard = @criteria.fetch("guard_redesign")

    assert_equal false, guard.fetch("inherit_combined_v1_unchanged")
    assert_equal false, guard.fetch("concrete_person_quantity_object_presence_is_fatal_by_itself")
    assert_includes guard.fetch("distinguish"), "independent_general_expression_or_analogy"
    assert_includes guard.fetch("distinguish"), "user_fact_assertion"
    assert_equal false, guard.fetch("runtime_llm_guard_allowed")
  end

  def test_pgvector_design_does_not_depend_on_full_ruby_scan
    database = @criteria.fetch("database")

    assert_equal "postgresql_pgvector", database.fetch("primary_candidate")
    assert_equal false, database.fetch("full_ruby_scan_allowed_for_production_design")
    assert_equal "abstraction_top_n", database.fetch("query_order").first
    assert_equal false, database.fetch("vector_version_mixing_allowed")
  end

  def test_design_issue_made_no_external_calls_or_implementation_changes
    execution = @criteria.fetch("execution_for_issue_41")

    %w[
      openai_api_calls anthropic_api_calls embedding_api_calls safety_api_calls
      abstraction_generation_calls line_reselection_calls other_paid_external_api_calls
    ].each { |key| assert_equal 0, execution.fetch(key) }
    assert_equal false, execution.fetch("line_pool_modified")
    assert_equal false, execution.fetch("database_migration_created")
  end
end
