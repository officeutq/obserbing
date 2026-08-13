# frozen_string_literal: true

require "csv"
require "tmpdir"
require_relative "test_helper"

class AbstractionEmbeddingComparisonTest < Minitest::Test
  def test_plan_uses_four_batches_and_only_approved_lines
    plan = comparison.plan(provider: "openai-small")

    assert_equal false, plan.fetch(:network_call_performed)
    assert_equal 6, plan.fetch(:total_requests)
    assert_equal 12, plan.fetch(:maximum_requests_with_retries)
    assert_equal 36, plan.fetch(:entry_count)
    assert_equal 96, plan.fetch(:approved_line_count)
    assert_equal({ "candidate" => 12, "retired" => 12 }, plan.fetch(:excluded_before_embedding))
    assert_equal [1, 5, 10, 20, 50], plan.fetch(:limits)
    assert_equal [0.35, 0.45, 0.55], plan.fetch(:similarity_thresholds)
    assert_operator plan.fetch(:maximum_cost_with_retries_jpy), :>, 0
  end

  def test_external_comparison_requires_explicit_permission
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      comparison.call(provider: "openai-small", entry_ids: ["E001"])
    end

    assert_equal "external_api_disabled", error.code
  end

  def test_fixture_records_determinism_stability_and_blind_evaluation
    Dir.mktmpdir do |directory|
      result = comparison.call(provider: "fixture", entry_ids: ["E001"], output_dir: directory)

      baseline = result.dig(:modes, "meaning_structure_baseline")
      abstraction = result.dig(:modes, "abstraction_only_v2")
      centroid = result.dig(:modes, "abstraction_only_v2_line_centroid")
      assert_equal 1, baseline.fetch(:entry_embedding_count)
      assert_equal 3, abstraction.fetch(:entry_embedding_count)
      assert_equal 288, centroid.fetch(:line_embedding_count)
      assert_equal "arithmetic_centroid_of_three_abstractions", centroid.fetch(:line_vector_aggregation)
      assert_equal 1.0, baseline.fetch(:deterministic_search_rate)
      assert_equal 1.0, abstraction.fetch(:deterministic_search_rate)
      assert_equal 0, baseline.fetch(:status_exclusion_violations)
      assert_equal 0, abstraction.fetch(:status_exclusion_violations)
      assert abstraction.dig(:generation_stability, :pairwise_by_limit, "20", :average_jaccard)
      assert_equal 0, result.dig(:comparison, :realtime_line_evaluation_calls)
      assert File.exist?(File.join(directory, "manifest.json"))
      assert File.exist?(File.join(directory, "candidate_sets.jsonl"))
      assert File.exist?(File.join(directory, "blind_mapping.csv"))
      assert_equal 61, CSV.read(File.join(directory, "blind_candidate_evaluation.csv"), encoding: "UTF-8").length
    end
  end

  def test_openai_comparison_uses_expected_batch_sizes_and_dimensions
    transport = FakeTransport.new(
      openai_embedding_response(count: 96, dimensions: 1536),
      openai_embedding_response(count: 1, dimensions: 1536),
      openai_embedding_response(count: 96, dimensions: 1536),
      openai_embedding_response(count: 3, dimensions: 1536),
      openai_embedding_response(count: 288, dimensions: 1536),
      openai_embedding_response(count: 3, dimensions: 1536)
    )
    external = AiLineSelection::AbstractionEmbeddingComparison.new(
      configuration: configuration,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai" },
      transport: transport
    )

    Dir.mktmpdir do |directory|
      result = external.call(provider: "openai-small", entry_ids: ["E001"], output_dir: directory)

      assert_equal 6, transport.requests.length
      assert_equal 1536, result.dig(:modes, "meaning_structure_baseline", :dimensions)
      assert_equal 1536, result.dig(:modes, "abstraction_only_v2", :dimensions)
      assert_equal 1.0, result.dig(:modes, "abstraction_only_v2", :deterministic_search_rate)
      assert_equal true, result.dig(:adoption_criteria, :candidate_or_retired_mixing_zero)
    end
  end

  private

  def comparison
    AiLineSelection::AbstractionEmbeddingComparison.new(configuration: configuration)
  end
end
