# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MeaningComparisonTest < Minitest::Test
  def test_direct_comparison_requires_explicit_external_permission
    comparison = AiLineSelection::MeaningComparison.new(configuration: configuration)

    assert_raises(AiLineSelection::ExternalApiDisabledError) do
      comparison.call(providers: ["openai"], repetitions: 1, entry_ids: ["E001"])
    end
  end

  def test_creates_blind_artifacts_and_quantitative_summary
    transport = FakeTransport.new(openai_response, openai_response)

    Dir.mktmpdir do |directory|
      report = AiLineSelection::MeaningComparison.new(
        configuration: configuration,
        allow_external_api: true,
        environment: { "OPENAI_API_KEY" => "test-openai" },
        transport: transport
      ).call(
        providers: ["openai"],
        repetitions: 2,
        entry_ids: ["E001"],
        output_dir: directory
      )

      assert_equal 2, report.fetch(:completed_executions)
      assert_equal 1.0, report.dig(:providers, "openai", :first_attempt_schema_success_rate)
      assert_equal 1.0, report.dig(:providers, "openai", :exact_stability, :rate)
      assert_equal 1.0, report.dig(:providers, "openai", :field_stability, :exact_rate_by_field, "themes")
      assert_equal 1.0, report.dig(:providers, "openai", :field_stability, :themes_pairwise_jaccard_average)
      assert File.file?(File.join(directory, "summary.json"))
      assert File.file?(File.join(directory, "human_evaluation.csv"))
      assert File.file?(File.join(directory, "blind_mapping.csv"))
      human = File.read(File.join(directory, "human_evaluation.csv"), encoding: "UTF-8")
      mapping = File.read(File.join(directory, "blind_mapping.csv"), encoding: "UTF-8")
      refute_includes human.lines.first, "provider"
      refute_includes human.lines.first, "model"
      assert_includes mapping.lines.first, "provider"
    end
  end
end
