# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class BV2DesignCriteriaArtifactTest < Minitest::Test
  def setup
    evaluations = File.join(configuration.root_dir, "data", "evaluations")
    @v1 = YAML.safe_load_file(File.join(evaluations, "b_v2_design_criteria_v1.yml"), permitted_classes: [], aliases: false)
    @criteria = YAML.safe_load_file(File.join(evaluations, "b_v2_design_criteria_v2.yml"), permitted_classes: [], aliases: false)
  end

  def test_v2_preserves_v1_as_a_pre_results_revision
    assert_equal 1, @v1.fetch("version")
    assert_equal "b-v2-pre-evaluation-criteria-v1", @v1.fetch("criteria_id")
    assert_equal 2, @criteria.fetch("version")
    assert_equal "b-v2-band-pass-design-v2", @criteria.fetch("design_id")
    assert_equal "b-v2-pre-evaluation-criteria-v1", @criteria.fetch("supersedes")
    assert_equal "before_any_b_v2_api_or_experiment_results", @criteria.dig("revision", "timing")
    assert_equal true, @criteria.dig("revision", "v1_artifact_preserved")
  end

  def test_band_pass_foundation_is_unchanged
    architecture = @criteria.fetch("unchanged_architecture")

    assert_equal "eligibility_lower_bound", architecture.fetch("abstraction_similarity_role")
    assert_equal "too_close_exclusion_upper_bound", architecture.fetch("surface_similarity_role")
    assert_equal "bounded_selection_and_diversity_assist_only", architecture.fetch("domain_role")
    assert_equal "none", architecture.fetch("structure_realtime_role")
    assert_equal 3, architecture.fetch("normal_external_request_limit")
    assert_equal 0, architecture.fetch("realtime_line_evaluation_llm_calls")
    assert_equal false, architecture.fetch("line_side_generation_at_post_time")
    assert_equal false, architecture.fetch("production_full_ruby_line_scan_allowed")
    assert_equal true, architecture.fetch("selection_reproducible_by_seed")
    assert_equal "silence", architecture.fetch("zero_eligible_outcome")
    assert_equal false, architecture.fetch("technical_errors_count_as_silence")
  end

  def test_gate_a_uses_current_line_pool_and_diagnostic_baseline
    gate = @criteria.fetch("gate_a")
    baseline = gate.fetch("baseline")

    assert_equal false, gate.fetch("is_production_adoption_gate")
    assert_equal "abstraction-only-v1-diagnostic", baseline.fetch("method")
    assert_equal 54, baseline.fetch("acceptable_count")
    assert_equal 29, baseline.fetch("direct_restatement_too_close_count")
    assert_equal 25, baseline.fetch("too_far_plus_unrelated_count")
    assert_equal 35, baseline.fetch("analogical_transfer_acceptable_count")
    assert_equal false, gate.fetch("absolute_product_quality_80_percent_alone_can_reject_architecture")
  end

  def test_gate_a_architecture_candidate_thresholds_are_fixed
    candidate = @criteria.dig("gate_a", "architecture_candidate_requires_all")

    assert_equal 0.70, candidate.dig("acceptable_outcome", "minimum_rate")
    assert_equal 76, candidate.dig("acceptable_outcome", "minimum_count_for_108")
    assert_equal 0.50, @criteria.dig("gate_a", "baseline", "acceptable_rate")
    assert_equal 20.0, candidate.dig("acceptable_outcome", "minimum_improvement_points_over_baseline")
    assert_in_delta(
      candidate.dig("acceptable_outcome", "minimum_rate"),
      @criteria.dig("gate_a", "baseline", "acceptable_rate") +
        (candidate.dig("acceptable_outcome", "minimum_improvement_points_over_baseline") / 100.0)
    )
    assert_equal 0.30, candidate.dig("direct_restatement_too_close", "minimum_reduction_rate_from_baseline")
    assert_equal 20, candidate.dig("direct_restatement_too_close", "maximum_count_for_108")
    assert_equal 30, candidate.dig("too_far_plus_unrelated", "maximum_count_for_108")
    assert_equal 32, candidate.dig("acceptable_analogical_transfer", "minimum_count_for_108")
    assert_equal 18, candidate.dig("all_three_repetitions_acceptable_entry", "minimum_count_for_36")
    assert_equal 21, candidate.dig("semantic_silence", "maximum_count_for_108")
    assert_equal 0, candidate.dig("required_zero_counts", "existing_normal_entry_safety_overblock")
    assert_equal 0, candidate.dig("required_zero_counts", "completed_flow_technical_errors")
  end

  def test_gate_a_has_three_explicit_outcomes_and_rejection_floors
    gate = @criteria.fetch("gate_a")

    assert_equal %w[architecture_candidate architecture_rejected further_selection_poc_required], gate.fetch("outcomes")
    assert_equal 10.0, gate.dig("rejection_floors", "acceptable_improvement_points_below")
    assert_equal 0.20, gate.dig("rejection_floors", "direct_restatement_too_close_reduction_rate_below")
    assert_equal 0.60, gate.dig("rejection_floors", "acceptable_analogical_transfer_retention_rate_below")
    assert_includes gate.fetch("further_selection_poc_when"), "technical_errors_or_missing_evidence_make_comparison_invalid"
  end

  def test_gate_b_owns_product_quality_thresholds
    gate = @criteria.fetch("gate_b")

    assert_equal "architecture_candidate", gate.fetch("applies_after_gate_a_outcome")
    assert_equal 0.80, gate.dig("acceptable_outcome_rate", "required_minimum")
    assert_equal 0.90, gate.dig("acceptable_outcome_rate", "target")
    assert_equal 0.60, gate.dig("all_three_repetitions_acceptable_entry_rate", "required_minimum")
    assert_equal 0.75, gate.dig("all_three_repetitions_acceptable_entry_rate", "target")
    assert_equal 0, gate.dig("required_zero_counts", "user_fact_assertion")
    assert_equal 0, gate.dig("required_zero_counts", "completed_flow_technical_errors")
    assert_equal 6.0, gate.dig("operations", "end_to_end_p95_seconds", "required_maximum")
    assert_equal 1.0, gate.dig("operations", "post_cost_jpy", "required_maximum")
  end

  def test_line_pool_improvement_freezes_the_architecture_baseline
    manifest = @criteria.fetch("gate_a_to_b_baseline_manifest")

    %w[
      profile_version embedding_provider_model_dimensions_and_normalization_version
      a_min s_max top_n selector_version_weights_and_seed_rule domain_taxonomy_version
      guard_policy_version current_approved_96_line_pool_hash
    ].each { |field| assert_includes manifest.fetch("fixed_fields"), field }
    assert_equal false, manifest.fetch("selection_method_changes_may_be_mixed_with_line_pool_changes")
  end

  def test_issue_42_smoke_scope_and_request_budget_are_fixed
    smoke = @criteria.dig("issue_42_smoke", "phase_2")

    assert_equal %w[E001 E003 E008 E023 E032 E035], smoke.fetch("entry_ids")
    assert_equal %w[L021 L083 L102 L118], smoke.fetch("line_ids")
    assert_equal 10, smoke.fetch("subject_count")
    assert_equal 2, smoke.fetch("candidate_version_maximum")
    assert_equal 3, smoke.fetch("repetitions")
    assert_equal 60, smoke.fetch("planned_request_maximum_without_retry")
    assert_equal 120, smoke.fetch("request_maximum_including_retry")
    assert_equal 50_000, smoke.fetch("input_and_output_token_maximum")
    assert_equal 500, smoke.fetch("cost_jpy_maximum")
  end

  def test_issue_42_requires_committed_preflight_and_protects_credentials
    smoke = @criteria.fetch("issue_42_smoke")

    assert_includes smoke.fetch("preflight_must_be_committed_before_external_api"), "provider"
    assert_includes smoke.fetch("preflight_must_be_committed_before_external_api"), "model"
    assert_includes smoke.fetch("preflight_must_be_committed_before_external_api"), "maximum_cost"
    assert_includes smoke.fetch("prohibited_persistence"), "api_keys"
    assert_includes smoke.fetch("saved_artifacts"), "normalized_abstraction_and_domain_outputs"
    assert_equal 0, smoke.fetch("issue_43_additional_external_api_calls_by_default")
  end

  def test_issue_46_remains_the_full_integrated_live_poc
    integrated = @criteria.fetch("issue_46_integrated_live_poc")

    assert_equal 96, integrated.fetch("fixed_current_approved_line_count")
    assert_equal 36, integrated.fetch("entry_count")
    assert_equal 3, integrated.fetch("repetitions")
    assert_includes integrated.fetch("includes"), "safety"
    assert_includes integrated.fetch("includes"), "surface_too_close_filter"
    assert_includes integrated.fetch("includes"), "reflective_distance_evaluation"
  end

  def test_epic_api_budget_is_split_between_smoke_and_integration
    budget = @criteria.fetch("external_api_budget")

    assert_equal 2_000, budget.fetch("epic_40_cost_jpy_maximum")
    assert_equal 500, budget.dig("issue_allocations", "issue_42_cost_jpy_maximum")
    assert_equal 1_500, budget.dig("issue_allocations", "issue_46_cost_jpy_maximum")
    assert_equal [43, 44, 45, 47, 48, 49], budget.fetch("default_zero_external_api_issues")
  end

  def test_design_revision_made_no_external_calls_or_implementation_changes
    execution = @criteria.fetch("execution_for_issue_41_revision")

    %w[
      openai_api_calls anthropic_api_calls embedding_api_calls safety_api_calls
      abstraction_generation_calls line_reselection_calls other_paid_external_api_calls
    ].each { |key| assert_equal 0, execution.fetch(key) }
    assert_equal false, execution.fetch("line_pool_modified")
    assert_equal false, execution.fetch("database_migration_created")
    assert_equal false, execution.fetch("production_code_implemented")
  end
end
