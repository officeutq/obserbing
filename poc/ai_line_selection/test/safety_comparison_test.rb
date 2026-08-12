# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class SafetyComparisonTest < Minitest::Test
  def test_external_comparison_requires_explicit_permission
    comparison = AiLineSelection::SafetyComparison.new(configuration: configuration)

    assert_raises(AiLineSelection::ExternalApiDisabledError) do
      comparison.call(providers: ["openai"], repetitions: 1, case_ids: ["S001"])
    end
  end

  def test_fixture_comparison_covers_fixed_dataset_and_never_generates_copy
    Dir.mktmpdir do |directory|
      report = AiLineSelection::SafetyComparison.new(configuration: configuration).call(
        providers: ["fixture"],
        repetitions: 3,
        output_dir: directory
      )

      provider = report.dig(:providers, "fixture")
      assert_equal 36, provider.fetch(:executions)
      assert_equal 1.0, provider.fetch(:safety_recall)
      assert_equal 1.0, provider.fetch(:normal_accuracy)
      assert_equal 1.0, provider.fetch(:indeterminate_accuracy)
      assert_equal 1.0, provider.dig(:exact_classification_and_reason_stability, :rate)
      assert_empty provider.fetch(:safety_miss_case_ids)
      assert_empty provider.fetch(:false_positive_case_ids)
      assert_empty provider.fetch(:unsafe_normal_flow_case_ids)
      assert_equal 0, provider.fetch(:downstream_operation_count_after_safety)
      assert_equal 0, provider.fetch(:ai_generated_safety_copy_count)
      assert provider.dig(:adoption_criteria, :eligible)
      assert_equal 0.0, report.fetch(:total_estimated_cost_jpy)

      outputs = File.read(File.join(directory, "provider_outputs.jsonl"), encoding: "UTF-8")
      data_loader.safety_cases.each { |item| refute_includes outputs, item.fetch("body") }
      assert File.file?(File.join(directory, "manifest.json"))
      assert File.file?(File.join(directory, "summary.json"))
    end
  end

  def test_indeterminate_never_routes_to_normal_flow
    transport = FakeTransport.new(openai_response(meaning: valid_safety(classification: "indeterminate")))

    Dir.mktmpdir do |directory|
      report = AiLineSelection::SafetyComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      ).call(
        providers: ["openai"],
        repetitions: 1,
        case_ids: ["S009"],
        output_dir: directory
      )

      record = JSON.parse(File.readlines(File.join(directory, "provider_outputs.jsonl"), encoding: "UTF-8").first)
      assert_equal "technical_error", record.dig("route", "status")
      assert_equal false, record.dig("route", "normal_flow_allowed")
      assert_nil record.dig("route", "next_operation")
      assert_empty report.dig(:providers, "openai", :unsafe_normal_flow_case_ids)
    end
  end

  def test_invalid_json_stops_without_allowing_normal_flow
    transport = FakeTransport.new(
      openai_response(body: "not-json"),
      openai_response(body: "still-not-json")
    )

    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::SafetyComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      )
      assert_raises(AiLineSelection::ResponseParseError) do
        comparison.call(
          providers: ["openai"],
          repetitions: 1,
          case_ids: ["S001"],
          output_dir: directory
        )
      end

      stopped = JSON.parse(File.read(File.join(directory, "stopped.json"), encoding: "UTF-8"))
      assert_equal false, stopped.fetch("normal_flow_allowed")
      assert_equal "response_parse_error", stopped.fetch("error_code")
      assert_equal 2, stopped.fetch("attempts").length
    end
  end

  def test_timeout_stops_without_allowing_normal_flow
    timeout = AiLineSelection::ProviderTimeoutError.new("openai")
    transport = FakeTransport.new(timeout, timeout)

    assert_external_failure_is_blocked(transport, AiLineSelection::ProviderTimeoutError, "provider_timeout_error")
  end

  def test_provider_failure_stops_without_allowing_normal_flow
    transport = FakeTransport.new(http_error(500), http_error(503))

    assert_external_failure_is_blocked(transport, AiLineSelection::ProviderServerError, "provider_server_error")
  end

  def test_plan_has_no_network_and_stays_within_request_cap
    report = AiLineSelection::SafetyComparison.new(configuration: configuration).plan(
      providers: %w[openai anthropic],
      repetitions: 3
    )

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 72, report.fetch(:total_requests)
    assert_equal 144, report.fetch(:maximum_requests_with_retries)
    assert report.fetch(:maximum_cost_with_one_retry_jpy).positive?
    assert_equal false, report.fetch(:technical_or_indeterminate_result_allows_normal_flow)
  end


  private

  def assert_external_failure_is_blocked(transport, error_class, error_code)
    Dir.mktmpdir do |directory|
      comparison = AiLineSelection::SafetyComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      )
      assert_raises(error_class) do
        comparison.call(
          providers: ["openai"],
          repetitions: 1,
          case_ids: ["S001"],
          output_dir: directory
        )
      end

      stopped = JSON.parse(File.read(File.join(directory, "stopped.json"), encoding: "UTF-8"))
      assert_equal error_code, stopped.fetch("error_code")
      assert_equal false, stopped.fetch("normal_flow_allowed")
      assert_equal 2, stopped.fetch("attempts").length
    end
  end
end
