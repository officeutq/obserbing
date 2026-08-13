# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class Bv2ProfileComparisonTest < Minitest::Test
  def test_plan_fixes_issue_42_subset_and_hard_limits_without_network
    report = AiLineSelection::Bv2ProfileComparison.new(configuration: configuration).plan

    assert_equal false, report.fetch(:network_call_performed)
    assert_equal 10, report.fetch(:item_count)
    assert_equal 3, report.fetch(:repetitions)
    assert_equal 60, report.fetch(:normal_requests)
    assert_equal 120, report.fetch(:maximum_requests_with_retries)
    assert_equal 50_000, report.fetch(:maximum_total_tokens)
    assert_equal 500.0, report.fetch(:maximum_cost_jpy)
    assert_operator report.fetch(:conservative_token_cap_cost_jpy), :<=, 500.0
    assert_equal %w[E001 E003 E008 E023 E032 E035 L021 L083 L102 L118], report.fetch(:item_ids)
  end

  def test_external_smoke_requires_explicit_permission
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::Bv2ProfileComparison.new(configuration: configuration).call(
        versions: ["b-v2-profile-single-v1"], repetitions: 1, item_ids: ["E001"]
      )
    end
    assert_equal "external_api_disabled", error.code
  end

  def test_fake_external_call_writes_only_normalized_outputs
    outputs = 3.times.map do
      openai_response(meaning: {
        "schema_version" => "b-v2-profile-primary-secondary-v1",
        "abstraction" => "選択と余白",
        "domain" => { "primary" => "choice", "secondary" => ["uncertainty"] }
      })
    end
    transport = FakeTransport.new(outputs)

    Dir.mktmpdir do |directory|
      report = AiLineSelection::Bv2ProfileComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      ).call(
        versions: ["b-v2-profile-primary-secondary-v1"],
        repetitions: 3,
        item_ids: ["E001"],
        output_dir: directory
      )

      assert_equal 3, report.fetch(:total_executions)
      assert_equal 1.0, report.dig(:versions, "b-v2-profile-primary-secondary-v1", :first_attempt_schema_success_rate)
      assert_equal 1.0, report.dig(:versions, "b-v2-profile-primary-secondary-v1", :abstraction_exact_stability_rate)
      rows = File.readlines(File.join(directory, "normalized_outputs.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal 3, rows.length
      refute rows.first.key?("request_id")
      refute rows.first.key?("source_text")
      assert_equal false, JSON.parse(File.read(File.join(directory, "manifest.json"))).fetch("provider_raw_response_saved")
    end
  end

  def test_primary_may_not_be_repeated_as_secondary
    response = openai_response(meaning: {
      "schema_version" => "b-v2-profile-primary-secondary-v1",
      "abstraction" => "選択と余白",
      "domain" => { "primary" => "choice", "secondary" => ["choice"] }
    })
    transport = FakeTransport.new(response)
    Dir.mktmpdir do |directory|
      assert_raises(AiLineSelection::SchemaValidationError) do
        AiLineSelection::Bv2ProfileComparison.new(
          configuration: configuration,
          allow_external_api: true,
          environment: { "OPENAI_API_KEY" => "test-openai" },
          transport: transport
        ).call(
          versions: ["b-v2-profile-primary-secondary-v1"],
          repetitions: 1,
          item_ids: ["E001"],
          output_dir: directory
        )
      end
    end
  end
end
