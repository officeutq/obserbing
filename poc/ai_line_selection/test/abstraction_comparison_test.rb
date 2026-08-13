# frozen_string_literal: true

require "csv"
require "tmpdir"
require_relative "test_helper"

class AbstractionComparisonTest < Minitest::Test
  def test_plan_covers_fixed_entries_and_lines_without_network
    report = AiLineSelection::AbstractionComparison.new(configuration: configuration).plan(
      provider: "openai",
      embedding_provider: "openai-small",
      repetitions: 3
    )

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 156, report.fetch(:item_count)
    assert_equal({ "entry" => 36, "line" => 120 }, report.fetch(:source_counts))
    assert_equal 468, report.fetch(:abstraction_requests)
    assert_equal 1, report.fetch(:semantic_embedding_requests)
    assert_equal 469, report.fetch(:total_requests)
    assert_operator report.fetch(:maximum_cost_with_retries_jpy), :<, 5_000
  end

  def test_fixture_generates_versioned_candidate_and_stability_artifacts
    Dir.mktmpdir do |directory|
      report = AiLineSelection::AbstractionComparison.new(configuration: configuration).call(
        provider: "fixture",
        embedding_provider: "fixture",
        repetitions: 3,
        item_ids: ["E001"],
        output_dir: directory
      )

      assert_equal 1.0, report.dig(:provider, :first_attempt_schema_success_rate)
      assert_equal 1.0, report.dig(:provider, :exact_stability, :rate)
      assert_equal 1.0, report.dig(:provider, :semantic_similarity_triage, :rate_at_or_above_threshold)
      assert_equal true, report.dig(:adoption_criteria, :semantic_equivalence_pending)
      assert_equal 0.0, report.fetch(:total_estimated_cost_jpy)
      assert_equal 1, CSV.read(File.join(directory, "blind_evaluation.csv"), headers: true).length

      candidates = YAML.safe_load_file(
        File.join(directory, "canonical_candidates.yml"),
        permitted_classes: [],
        aliases: false
      ).fetch("abstractions")
      assert_equal "E001", candidates.first.fetch("id")
      assert_equal "abstraction-only-v1", candidates.first.fetch("prompt_version")
      assert_equal "pending", candidates.first.fetch("review_status")
    end
  end

  def test_external_comparison_requires_explicit_permission
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::AbstractionComparison.new(configuration: configuration).call(
        provider: "openai",
        embedding_provider: "openai-small",
        repetitions: 1,
        item_ids: ["E001"]
      )
    end

    assert_equal "external_api_disabled", error.code
  end

  def test_entry_and_line_can_be_selected_by_stable_id
    entry = AiLineSelection::AbstractionComparison.new(configuration: configuration).plan(
      provider: "fixture",
      embedding_provider: "fixture",
      repetitions: 1,
      item_ids: ["E001"]
    )
    line = AiLineSelection::AbstractionComparison.new(configuration: configuration).plan(
      provider: "fixture",
      embedding_provider: "fixture",
      repetitions: 1,
      item_ids: ["L001"]
    )

    assert_equal({ "entry" => 1 }, entry.fetch(:source_counts))
    assert_equal({ "line" => 1 }, line.fetch(:source_counts))
  end

  def test_v2_uses_independent_prompt_and_schema_versions
    report = AiLineSelection::AbstractionComparison.new(
      configuration: configuration,
      version: "abstraction-only-v2"
    ).plan(
      provider: "fixture",
      embedding_provider: "fixture",
      repetitions: 1,
      item_ids: ["E026"]
    )

    assert_equal "abstraction_only_v2", report.fetch(:operation)
    assert_equal "abstraction-only-v2", report.dig(:provider, "prompt_version")
    assert_equal "abstraction-only-v2", report.dig(:provider, "schema_version")
  end

  def test_preliminary_review_updates_summary_and_exports_versioned_abstractions
    Dir.mktmpdir do |directory|
      results = File.join(directory, "results")
      export = File.join(directory, "data", "abstractions.yml")
      judgments = File.join(directory, "judgments.yml")
      AiLineSelection::AbstractionComparison.new(configuration: configuration).call(
        provider: "fixture",
        embedding_provider: "fixture",
        repetitions: 3,
        item_ids: ["E001"],
        output_dir: results
      )
      File.write(judgments, YAML.dump({
        "comparison_version" => "abstraction-only-v1",
        "judge" => "codex_preliminary",
        "all_items_reviewed" => true,
        "defaults" => {
          "confidence" => "high",
          "candidate" => { "usability" => 3, "abstraction_level_match" => true },
          "baseline" => { "usability" => 3, "abstraction_level_match" => true },
          "semantic" => { "equivalent" => true }
        }
      }), mode: "w:UTF-8")

      review = AiLineSelection::AbstractionPreliminaryReviewer.new(
        configuration: configuration,
        results_dir: results,
        judgments_path: judgments,
        export_path: export
      ).call

      assert_equal 1.0, review.dig(:candidate, :usability_two_or_higher_rate)
      assert_equal 1.0, review.dig(:semantic_equivalence, :rate)
      assert_equal true, review.dig(:adoption_criteria, :eligible_for_embedding_comparison)
      assert_equal 0, review.fetch(:human_review_required_count)
      assert_equal false, JSON.parse(File.read(File.join(results, "summary.json"), encoding: "UTF-8"))
                                    .fetch("human_evaluation_pending")
      abstractions = YAML.safe_load_file(export, permitted_classes: [], aliases: false).fetch("abstractions")
      assert_equal ["E001"], abstractions.map { |item| item.fetch("id") }
    end
  end
end
