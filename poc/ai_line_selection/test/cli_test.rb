# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class CliTest < Minitest::Test
  def test_doctor_reports_expected_counts_and_no_external_api
    output = StringIO.new
    status = AiLineSelection::CLI.start(["doctor"], output: output, error_output: StringIO.new)

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal false, document.fetch("external_api_enabled")
    assert_equal 36, document.dig("datasets", "entries")
    assert_equal 120, document.dig("datasets", "lines")
  end

  def test_prepare_redacts_entry_and_performs_no_network_call
    output = StringIO.new
    status = AiLineSelection::CLI.start(
      ["prepare", "--entry-id", "E001", "--operation", "safety"],
      output: output,
      error_output: StringIO.new
    )

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal false, document.fetch("network_call_performed")
    refute_includes output.string, data_loader.entry("E001").fetch("body")
  end

  def test_offline_evaluation_covers_all_fixed_cases
    output = StringIO.new
    status = AiLineSelection::CLI.start(
      ["evaluate", "--repetitions", "1"],
      output: output,
      error_output: StringIO.new
    )

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal 36, document.fetch("normal_runs")
    assert_equal 12, document.fetch("safety_runs")
    assert_empty document.fetch("failures")
  end

  def test_meaning_comparison_requires_explicit_external_api_flag
    output = StringIO.new
    errors = StringIO.new

    status = AiLineSelection::CLI.start(
      ["compare-meaning", "--providers", "openai", "--repetitions", "1", "--entry-id", "E001"],
      output: output,
      error_output: errors
    )

    assert_equal 2, status
    assert_empty output.string
    assert_equal "external_api_disabled", JSON.parse(errors.string).fetch("error")
  end

  def test_review_meaning_requires_results_directory
    errors = StringIO.new
    status = AiLineSelection::CLI.start(
      ["review-meaning"],
      input: StringIO.new,
      output: StringIO.new,
      error_output: errors
    )

    assert_equal 2, status
    assert_equal "configuration_error", JSON.parse(errors.string).fetch("error")
  end
end
