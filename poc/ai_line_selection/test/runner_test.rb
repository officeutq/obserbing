# frozen_string_literal: true

require_relative "test_helper"

class RunnerTest < Minitest::Test
  def test_runs_normal_flow_with_fixture
    runner = AiLineSelection::Runner.new(configuration: configuration, telemetry_path: nil)
    result = runner.run(entry_id: "E001")

    assert_includes %w[line silence], result.fetch(:status)
    assert_equal 4, result.dig(:telemetry, :operations)
    assert_equal 0.0, result.dig(:telemetry, :estimated_cost_jpy)
    assert result.dig(:evaluation, :candidate_recall).between?(0.0, 1.0)
    refute_includes runner.telemetry.events.to_s, data_loader.entry("E001").fetch("body")
  end

  def test_safety_stops_after_classification
    runner = AiLineSelection::Runner.new(configuration: configuration, telemetry_path: nil)
    result = runner.run_entry(data_loader.safety_cases.find { |item| item.fetch("id") == "S001" })

    assert_equal "safety", result.fetch(:status)
    assert_equal 1, result.dig(:telemetry, :operations)
    assert_equal "SAFETY_COPY_TBD", result.fetch(:safety_response_id)
  end

  def test_indeterminate_safety_never_enters_normal_flow
    runner = AiLineSelection::Runner.new(configuration: configuration, telemetry_path: nil)
    safety_case = data_loader.safety_cases.find { |item| item.fetch("id") == "S009" }

    assert_raises(AiLineSelection::SafetyIndeterminateError) { runner.run_entry(safety_case) }
    assert_equal 1, runner.telemetry.summary.fetch(:operations)
  end

  def test_pending_external_stops_on_first_operation
    runner = AiLineSelection::Runner.new(
      configuration: configuration,
      adapter_override: "pending_external",
      telemetry_path: nil
    )

    assert_raises(AiLineSelection::ExternalApiDisabledError) { runner.run(entry_id: "E001") }
    assert_equal "external_api_disabled", runner.telemetry.events.last.fetch(:error_code)
  end
end
