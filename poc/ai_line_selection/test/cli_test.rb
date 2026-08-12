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

  def test_embedding_plan_performs_no_network_call
    output = StringIO.new
    status = AiLineSelection::CLI.start(
      ["plan-embedding", "--providers", "openai-small,openai-large"],
      output: output,
      error_output: StringIO.new
    )

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal false, document.fetch("network_call_performed")
    assert_equal 12, document.fetch("total_requests")
    assert_equal 24, document.fetch("maximum_requests_with_retries")
  end

  def test_safety_plan_performs_no_network_call
    output = StringIO.new
    status = AiLineSelection::CLI.start(
      ["plan-safety", "--providers", "openai,anthropic", "--repetitions", "3"],
      output: output,
      error_output: StringIO.new
    )

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal false, document.fetch("network_call_performed")
    assert_equal 72, document.fetch("total_requests")
    assert_equal 144, document.fetch("maximum_requests_with_retries")
  end

  def test_external_safety_comparison_requires_explicit_flag
    errors = StringIO.new
    status = AiLineSelection::CLI.start(
      ["compare-safety", "--providers", "openai", "--case-id", "S001"],
      output: StringIO.new,
      error_output: errors
    )

    assert_equal 2, status
    assert_equal "external_api_disabled", JSON.parse(errors.string).fetch("error")
  end

  def test_external_embedding_comparison_requires_explicit_flag
    errors = StringIO.new
    status = AiLineSelection::CLI.start(
      ["compare-embedding", "--providers", "openai-small", "--variants", "original", "--limits", "20"],
      output: StringIO.new,
      error_output: errors
    )

    assert_equal 2, status
    assert_equal "external_api_disabled", JSON.parse(errors.string).fetch("error")
  end

  def test_line_evaluation_plan_performs_no_network_call
    output = StringIO.new
    status = AiLineSelection::CLI.start(
      ["plan-line-evaluation", "--providers", "openai,anthropic", "--repetitions", "3"],
      output: output,
      error_output: StringIO.new
    )

    document = JSON.parse(output.string)
    assert_equal 0, status
    assert_equal false, document.fetch("network_call_performed")
    assert_equal 218, document.fetch("total_requests")
  end

  def test_external_line_evaluation_requires_explicit_flag
    errors = StringIO.new
    status = AiLineSelection::CLI.start(
      ["compare-line-evaluation", "--providers", "openai", "--entry-id", "E001"],
      output: StringIO.new,
      error_output: errors
    )

    assert_equal 2, status
    assert_equal "external_api_disabled", JSON.parse(errors.string).fetch("error")
  end

  def test_review_line_evaluation_requires_results_directory
    errors = StringIO.new
    status = AiLineSelection::CLI.start(
      ["review-line-evaluation"],
      input: StringIO.new,
      output: StringIO.new,
      error_output: errors
    )

    assert_equal 2, status
    assert_equal "configuration_error", JSON.parse(errors.string).fetch("error")
  end
end
