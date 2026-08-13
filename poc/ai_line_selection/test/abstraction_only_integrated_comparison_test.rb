# frozen_string_literal: true

require "tmpdir"
require "yaml"
require_relative "test_helper"

class AbstractionOnlyIntegratedComparisonTest < Minitest::Test
  def test_component_status_prevents_ineligible_chain_from_becoming_candidate
    path = File.join(configuration.root_dir, "data", "evaluations", "additional_poc_components_v1.yml")
    document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)

    assert_equal false, document.dig("integration", "candidate_chain_constructible")
    assert_equal false, document.dig("components", "embedding", "eligible")
    assert_equal false, document.dig("components", "ruby_selection", "eligible")
    assert_equal "abstraction-only-v1-diagnostic", document.dig("integration", "diagnostic_chain_name")
  end

  def test_plan_fixes_three_realtime_calls_per_post_and_stays_within_budget
    report = AiLineSelection::AbstractionOnlyIntegratedComparison.new(configuration: configuration).plan(
      mode: "diagnostic", repetitions: 3
    )

    assert_equal false, report.fetch(:network_call_performed)
    assert report.fetch(:diagnostic_only)
    assert_equal [22, 24], report.fetch(:ineligible_component_issues)
    assert_equal 325, report.fetch(:normal_flow_requests)
    assert_equal 36, report.fetch(:offline_quality_requests)
    assert_equal 0, report.fetch(:realtime_line_evaluation_calls)
    assert_equal 3, report.fetch(:external_api_calls_per_normal_post)
    assert_operator report.fetch(:maximum_cost_with_retries_jpy), :<, 5_000
  end

  def test_fixture_executes_connected_flow_and_is_resumable
    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::AbstractionOnlyIntegratedComparison.new(configuration: configuration)
      first = comparison.call(mode: "fixture", repetitions: 3, entry_ids: ["E001"], output_dir: directory)
      second = comparison.call(mode: "fixture", repetitions: 3, entry_ids: ["E001"], output_dir: directory)

      assert_equal 3, first.fetch(:normal_flow_execution_count)
      assert_equal 3, second.fetch(:normal_flow_execution_count)
      assert_equal 0, first.dig(:safety, :existing_normal_overblock_count)
      assert_equal 0, first.dig(:errors_and_silence, :technical_error_count)
      assert_equal 0, first.dig(:api, :realtime_line_evaluation_calls)
      assert_equal 3.0, first.dig(:api, :normal_flow_calls_per_post)
      assert_equal 1.0, first.dig(:selection, :same_seed_ruby_reproducibility_rate)
      assert_equal 3, File.readlines(File.join(directory, "provider_outputs.jsonl"), encoding: "UTF-8").length
      assert_equal 3, File.readlines(File.join(directory, "candidate_sets.jsonl"), encoding: "UTF-8").length
    end
  end

  def test_diagnostic_execution_requires_explicit_external_flag
    comparison = AiLineSelection::AbstractionOnlyIntegratedComparison.new(configuration: configuration)

    assert_raises(AiLineSelection::ExternalApiDisabledError) do
      comparison.call(mode: "diagnostic", repetitions: 1, entry_ids: ["E001"])
    end
  end

  def test_codex_review_covers_only_unique_decided_pairs
    path = File.join(configuration.root_dir, "data", "evaluations", "integrated_replay_codex_review_v1.yml")
    document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    reviews = document.fetch("reviews")
    pairs = reviews.map { |review| [review.fetch("entry_id"), review.fetch("line_id")] }

    assert_equal 14, reviews.length
    assert_equal pairs.length, pairs.uniq.length
    assert reviews.all? { |review| [true, false].include?(review.fetch("acceptable")) }
    assert reviews.none? { |review| review.fetch("confidence") == "low" }
  end

  def test_external_integrated_flow_sends_abstraction_as_text
    safety = {
      "schema_version" => "additional-v3", "classification" => "normal",
      "reason_code" => "none", "confidence" => 0.98
    }
    abstraction = {
      "schema_version" => "abstraction-only-v2", "abstraction" => "選択前のためらい"
    }
    transport = FakeTransport.new(
      openai_embedding_response(count: 96, dimensions: 1536),
      openai_response(meaning: safety),
      openai_response(meaning: abstraction),
      openai_embedding_response(count: 1, dimensions: 1536)
    )

    Dir.mktmpdir do |directory|
      summary = AiLineSelection::AbstractionOnlyIntegratedComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      ).call(
        mode: "diagnostic", repetitions: 1, entry_ids: ["E001"],
        include_offline_quality: false, output_dir: directory
      )

      abstraction_request = JSON.parse(transport.requests.fetch(2).fetch(:body))
      assert_equal data_loader.entry("E001").fetch("body"), abstraction_request.fetch("input")
      assert_equal 1, summary.dig(:selection, :selected_count)
      assert_equal 0, summary.dig(:errors_and_silence, :technical_error_count)
    end
  end

  def test_resume_includes_successful_orphan_request_in_usage_ledger
    safety = {
      "schema_version" => "additional-v3", "classification" => "normal",
      "reason_code" => "none", "confidence" => 0.98
    }
    abstraction = {
      "schema_version" => "abstraction-only-v2", "abstraction" => "選択前のためらい"
    }
    transport = FakeTransport.new(
      openai_embedding_response(count: 96, dimensions: 1536),
      openai_response(meaning: safety),
      RuntimeError.new("abstraction transport failed"),
      openai_response(meaning: safety),
      openai_response(meaning: abstraction),
      openai_embedding_response(count: 1, dimensions: 1536)
    )

    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::AbstractionOnlyIntegratedComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      )
      assert_raises(AiLineSelection::Error) do
        comparison.call(
          mode: "diagnostic", repetitions: 1, entry_ids: ["E001"],
          include_offline_quality: false, output_dir: directory
        )
      end

      summary = comparison.call(
        mode: "diagnostic", repetitions: 1, entry_ids: ["E001"],
        include_offline_quality: false, output_dir: directory
      )

      assert_equal 5, summary.dig(:api, :total_requests_including_retries)
      assert_equal 4, summary.dig(:api, :logical_completed_request_count)
      assert_equal 1, summary.dig(:api, :resumed_orphan_request_count)
      assert_operator summary.dig(:api, :usage, :estimated_cost_jpy), :>, summary.dig(:api, :normal_flow_usage, :estimated_cost_jpy)
      refute_path_exists File.join(directory, "stopped.json")
    end
  end
end
