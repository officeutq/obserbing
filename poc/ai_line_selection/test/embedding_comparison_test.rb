# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class EmbeddingComparisonTest < Minitest::Test
  def test_plan_estimates_requests_and_excludes_unapproved_lines_without_network
    plan = AiLineSelection::EmbeddingComparison.new(configuration: configuration).plan(
      providers: %w[openai-small openai-large]
    )

    assert_equal false, plan.fetch(:network_call_performed)
    assert_equal 12, plan.fetch(:total_requests)
    assert_equal 24, plan.fetch(:maximum_requests_with_retries)
    assert_equal 96, plan.fetch(:approved_line_count)
    assert_equal({ "candidate" => 12, "retired" => 12 }, plan.fetch(:excluded_before_embedding))
    assert_operator plan.fetch(:maximum_cost_with_one_retry_jpy), :>, 0
  end

  def test_external_comparison_requires_explicit_permission
    comparison = AiLineSelection::EmbeddingComparison.new(configuration: configuration)

    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      comparison.call(providers: ["openai-small"], variants: ["original"], limits: [20])
    end

    assert_equal "external_api_disabled", error.code
  end

  def test_fixture_compares_all_variants_and_records_metrics
    Dir.mktmpdir do |directory|
      result = AiLineSelection::EmbeddingComparison.new(configuration: configuration).call(
        providers: ["fixture"],
        output_dir: directory
      )

      variants = result.dig(:providers, "fixture")
      assert_equal AiLineSelection::EmbeddingTextBuilder::VARIANTS.sort, variants.keys.sort
      assert_equal 64, variants.fetch("original").fetch(:dimensions)
      assert_equal 96, variants.fetch("original").fetch(:indexed_line_count)
      assert_equal 0, variants.fetch("original").dig(:limits, "20", :status_exclusion_violations)
      assert_nil result.dig(:decision, :recommended_poc_candidate)
      assert File.exist?(File.join(directory, "manifest.json"))
      assert File.exist?(File.join(directory, "entry_results.jsonl"))
      assert File.exist?(File.join(directory, "summary.json"))
    end
  end

  def test_fixture_ranking_is_deterministic
    rankings = 2.times.map do
      Dir.mktmpdir do |directory|
        result = AiLineSelection::EmbeddingComparison.new(configuration: configuration).call(
          providers: ["fixture"],
          variants: ["normalized_text"],
          limits: [20, 50],
          output_dir: directory
        )
        result.dig(:providers, "fixture", "normalized_text", :ranking)
      end
    end

    assert_equal rankings.first, rankings.last
  end

  def test_external_comparison_runs_through_fake_transport_only
    transport = FakeTransport.new(
      openai_embedding_response(count: 96, dimensions: 1536),
      openai_embedding_response(count: 1, dimensions: 1536)
    )
    comparison = AiLineSelection::EmbeddingComparison.new(
      configuration: configuration,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai" },
      transport: transport
    )

    Dir.mktmpdir do |directory|
      result = comparison.call(
        providers: ["openai-small"],
        variants: ["normalized_text"],
        limits: [20],
        entry_ids: ["E001"],
        output_dir: directory
      )

      summary = result.dig(:providers, "openai-small", "normalized_text")
      assert_equal 1536, summary.fetch(:dimensions)
      assert_equal 2, transport.requests.length
      assert_equal 291, summary.dig(:usage, :input_units)
      assert_equal 0, summary.dig(:limits, "20", :status_exclusion_violations)
      assert_nil result.dig(:decision, :recommended_poc_candidate)
    end
  end
end
