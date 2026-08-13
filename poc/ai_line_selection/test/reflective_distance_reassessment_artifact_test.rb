# frozen_string_literal: true

require "csv"
require "digest"
require "yaml"
require_relative "test_helper"

class ReflectiveDistanceReassessmentArtifactTest < Minitest::Test
  def setup
    @evaluation_dir = File.join(configuration.root_dir, "data", "evaluations")
    @rubric_path = File.join(@evaluation_dir, "reflective_distance_rubric_v1.yml")
    @judgments_path = File.join(@evaluation_dir, "reflective_distance_codex_judgments_v1.csv")
    @display_path = File.join(@evaluation_dir, "reflective_distance_display_pairs_v1.csv")
    @previous_path = File.join(@evaluation_dir, "reflective_distance_previous_labels_v1.csv")
    @summary_path = File.join(@evaluation_dir, "reflective_distance_reassessment_v1.yml")

    @rubric = YAML.safe_load_file(@rubric_path, permitted_classes: [], aliases: false)
    @judgments = CSV.read(@judgments_path, headers: true, encoding: "UTF-8")
    @displays = CSV.read(@display_path, headers: true, encoding: "UTF-8")
    @summary = YAML.safe_load_file(@summary_path, permitted_classes: [], aliases: false)
  end

  def test_rubric_was_frozen_before_old_labels_were_joined
    assert_equal "reflective-distance-v1", @rubric.fetch("rubric_id")
    assert_equal "frozen", @rubric.fetch("status")
    assert_equal true, @rubric.fetch("frozen_before_reassessment")
    assert_equal false, @rubric.dig("reporting", "external_api_calls_allowed")
    assert_equal "51b398f", @summary.dig("audit", "rubric_frozen_commit")
    assert_equal true, @summary.dig("audit", "old_labels_joined_after_blind_judgment_commits")
  end

  def test_every_stored_display_has_a_schema_valid_blind_judgment
    judgment_ids = @judgments.map { |row| row.fetch("pair_id") }
    assert_equal judgment_ids.uniq.length, judgment_ids.length

    @displays.each do |display|
      pair_id = "#{display.fetch('entry_id')}/#{display.fetch('line_id')}"
      assert_includes judgment_ids, pair_id
    end

    @judgments.each do |judgment|
      assert_includes %w[true false], judgment.fetch("acceptable")
      assert_includes %w[too_close just_right too_far not_obserbing], judgment.fetch("distance")
      assert_includes %w[same_domain analogical_transfer direct_restatement weak_connection unrelated], judgment.fetch("relation_type")
      assert_includes %w[high medium low], judgment.fetch("confidence")
      refute_empty judgment.fetch("reason")
    end
  end

  def test_display_inventory_preserves_all_existing_results_without_rerunning_selection
    live = @displays.select { |row| row.fetch("dataset") == "abstraction_only_issue36" }
    baseline = @displays.select { |row| row.fetch("dataset") == "selected_v1_all_line_displays" }

    assert_equal 108, live.length
    assert_equal 98, baseline.length
    assert_equal 32, baseline.count { |row| row.fetch("blind_sample") == "true" }
  end

  def test_abstraction_only_summary_and_transition_counts_are_fixed
    result = @summary.dig("datasets", "abstraction_only_issue36")
    transitions = @summary.dig("old_to_new", "abstraction_only_issue36")

    assert_equal 108, result.fetch("evaluated_count")
    assert_equal 54, result.fetch("acceptable_count")
    assert_equal 0.5, result.fetch("acceptable_rate")
    assert_equal 35, result.fetch("analogical_transfer_count")
    assert_equal 1.0, result.fetch("analogical_transfer_acceptable_rate")
    assert_equal 13, result.fetch("low_confidence_count")
    assert_equal 5, transitions.fetch("old_too_close_to_new_acceptable_count")
    assert_equal 0, transitions.fetch("old_too_far_to_new_acceptable_count")
    assert_equal 1, transitions.fetch("old_fatal_to_new_analogical_transfer_count")
    assert_equal 28, transitions.fetch("old_acceptable_to_new_unacceptable_count")
  end

  def test_factual_assertion_is_separate_from_analogy
    result = @summary.dig("datasets", "abstraction_only_issue36")
    e001 = @summary.dig("representative_cases", "e001_l083")
    e033 = @summary.dig("representative_cases", "e033_l102")

    assert_equal 0, result.fetch("user_fact_assertion_count")
    assert_equal true, e001.fetch("old_fatal_grounding_mismatch")
    assert_equal "analogical_transfer", e001.fetch("new_relation_type")
    assert_equal false, e001.fetch("new_user_fact_assertion")
    assert_equal true, e001.fetch("new_acceptable")
    assert_equal true, e033.fetch("old_fatal_grounding_mismatch")
    assert_equal "analogical_transfer", e033.fetch("new_relation_type")
    assert_equal false, e033.fetch("new_user_fact_assertion")
  end

  def test_baseline_is_reassessed_under_same_rubric_with_comparison_limit
    sample = @summary.dig("datasets", "selected_v1_blind_sample_32")
    all_stored = @summary.dig("datasets", "selected_v1_all_stored_line_displays_98")

    assert_equal 9, sample.fetch("acceptable_count")
    assert_equal 0.2813, sample.fetch("acceptable_rate")
    assert_equal 27, all_stored.fetch("acceptable_count")
    assert_equal 0.2755, all_stored.fetch("acceptable_rate")
    assert_equal 22.45, @summary.dig("comparison", "delta_percentage_points")
    refute_empty @summary.dig("comparison", "direct_comparison_limitation")
  end

  def test_threshold_decision_and_zero_api_execution_are_explicit
    execution = @summary.fetch("execution")

    assert_equal 0, execution.fetch("external_ai_api_calls")
    assert_equal 0, execution.fetch("embedding_api_calls")
    assert_equal 0, execution.fetch("safety_calls")
    assert_equal 0, execution.fetch("abstraction_calls")
    assert_equal 0, execution.fetch("line_reselection_calls")
    assert_equal false, @summary.dig("acceptance", "abstraction_only_met")
    assert_equal false, @summary.dig("decision", "previous_non_adoption_reversed")
    assert_equal false, @summary.dig("decision", "reopen_epic_27")
  end

  def test_versioned_source_hashes_match
    paths = {
      "rubric_sha256" => @rubric_path,
      "judgments_sha256" => @judgments_path,
      "display_pairs_sha256" => @display_path,
      "previous_labels_sha256" => @previous_path,
      "entries_sha256" => File.join(configuration.root_dir, "data", "entries.yml"),
      "lines_sha256" => File.join(configuration.root_dir, "data", "lines.yml")
    }

    paths.each do |key, path|
      content = File.binread(path).gsub("\r\n", "\n")
      assert_equal Digest::SHA256.hexdigest(content), @summary.dig("source_hashes", key)
    end
  end
end
