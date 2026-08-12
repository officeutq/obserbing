# frozen_string_literal: true

require "csv"
require "tmpdir"
require_relative "test_helper"

class IntegratedComparisonTest < Minitest::Test
  def test_selected_plan_is_network_free_and_covers_the_fixed_workload
    report = AiLineSelection::IntegratedComparison.new(configuration: configuration).plan(
      mode: "selected",
      repetitions: 3,
      safety_case_repetitions: 3
    )

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 469, report.fetch(:total_requests)
    assert_equal 938, report.fetch(:maximum_requests_with_retries)
    assert_operator report.fetch(:maximum_cost_with_one_retry_jpy), :>, 0
    assert_operator report.fetch(:maximum_cost_with_one_retry_jpy), :<, 5000
    assert_equal "gpt-5.6-terra", report.dig(:components, :safety, :model)
    assert_equal "text-embedding-3-small", report.dig(:components, :embedding, :model)
    assert_equal "claude-sonnet-5", report.dig(:components, :line_evaluation, :model)
  end

  def test_selected_run_stops_before_network_without_explicit_permission
    transport = FakeTransport.new

    assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::IntegratedComparison.new(
        configuration: configuration,
        transport: transport
      ).call(
        mode: "selected",
        repetitions: 1,
        safety_case_repetitions: 1,
        entry_ids: ["E001"]
      )
    end

    assert_empty transport.requests
  end

  def test_fixture_run_executes_the_full_chain_and_writes_blind_review_artifacts
    Dir.mktmpdir("integrated-test") do |directory|
      report = AiLineSelection::IntegratedComparison.new(configuration: configuration).call(
        mode: "fixture",
        repetitions: 1,
        safety_case_repetitions: 1,
        entry_ids: ["E001"],
        output_dir: directory
      )

      assert report.fetch(:completed)
      assert_equal({ "line" => 1 }, report.dig(:normal_flow, :status_counts))
      assert_equal 12, report.dig(:safety_gate, :executions)
      assert_equal 1.0, report.dig(:safety_gate, :classification_accuracy)
      assert_equal 1.0, report.dig(:safety_gate, :safety_recall)
      assert_empty report.dig(:safety_gate, :unsafe_normal_flow_case_ids)
      assert_equal 0.0, report.fetch(:total_estimated_cost_jpy)

      evaluation = CSV.read(File.join(directory, "human_evaluation.csv"), headers: true, encoding: "bom|utf-8")
      mapping = CSV.read(File.join(directory, "blind_mapping.csv"), headers: true, encoding: "bom|utf-8")
      assert_equal 1, evaluation.length
      assert_equal 1, mapping.length
      refute_includes evaluation.headers, "provider"

      provider_output = File.read(File.join(directory, "provider_outputs.jsonl"), encoding: "UTF-8")
      refute_includes provider_output, data_loader.entry("E001").fetch("body")
    end
  end

  def test_external_technical_error_is_retried_then_recorded_as_a_stop_not_silence
    approved_count = data_loader.lines.count { |line| line.fetch("status") == "approved" }
    transport = FakeTransport.new(
      openai_embedding_response(count: approved_count, dimensions: 1536),
      http_error(500),
      http_error(500)
    )

    Dir.mktmpdir("integrated-stop-test") do |directory|
      error = assert_raises(AiLineSelection::ProviderServerError) do
        AiLineSelection::IntegratedComparison.new(
          configuration: configuration,
          allow_external_api: true,
          environment: { "OPENAI_API_KEY" => "test-openai", "ANTHROPIC_API_KEY" => "test-anthropic" },
          transport: transport
        ).call(
          mode: "selected",
          repetitions: 1,
          safety_case_repetitions: 1,
          entry_ids: ["E001"],
          output_dir: directory
        )
      end

      assert_equal "provider_server_error", error.code
      stopped = JSON.parse(File.read(File.join(directory, "stopped.json"), encoding: "UTF-8"))
      assert_equal false, stopped.fetch("semantic_silence")
      assert_equal false, stopped.fetch("normal_flow_allowed_after_error")
      assert_equal 2, stopped.fetch("attempts").length
      assert_equal 3, transport.requests.length
    end
  end

  def test_selection_stability_does_not_count_repeatable_technical_errors_as_stable
    comparison = AiLineSelection::IntegratedComparison.new(configuration: configuration)
    context = { entries: [{ "id" => "E001" }, { "id" => "E002" }], repetitions: 3 }
    records = 3.times.flat_map do
      [
        { entry_id: "E001", status: "line", rails_selection: { line_id: "L001" } },
        { entry_id: "E002", status: "technical_error" }
      ]
    end

    result = comparison.send(:selection_stability, context, records)

    assert_equal 1, result.fetch(:stable_entries)
    assert_equal 2, result.fetch(:total_entries)
    assert_equal 0.5, result.fetch(:rate)
  end
end
