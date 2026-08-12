# frozen_string_literal: true

require "csv"
require "stringio"
require "tmpdir"
require_relative "test_helper"

class LineEvaluationReviewerTest < Minitest::Test
  def test_only_low_confidence_rows_are_sent_to_human_and_judges_stay_separate
    Dir.mktmpdir do |directory|
      AiLineSelection::LineEvaluationComparison.new(configuration: configuration).call(
        providers: ["fixture"],
        repetitions: 1,
        entry_ids: %w[E001 E002],
        embedding_provider: "fixture",
        output_dir: directory
      )
      add_pending_human_criterion(directory)
      prepare_preliminary_rows(directory)
      output = StringIO.new
      result = AiLineSelection::LineEvaluationReviewer.new(
        configuration: configuration,
        results_dir: directory,
        input: StringIO.new("j\ny\n\n人が確認\n"),
        output: output
      ).call

      assert_equal "complete", result.fetch(:status)
      assert_equal({ "codex_preliminary" => 1, "human" => 1 }, result.fetch(:judge_counts))
      assert_equal 1, result.fetch(:human_reviewed_outputs)
      assert_includes output.string, "今回の確認対象: 1"
      summary = JSON.parse(File.read(File.join(directory, "summary.json")))
      assert_equal "complete", summary.dig("human_evaluation", "status")
      assert_equal false, summary.dig("adoption_criteria", "final_quality_decision_pending_human_evaluation")
      assert_equal true, summary.dig("adoption_criteria", "human_acceptable_at_least_80_percent")
      assert_equal true, summary.dig("adoption_criteria", "human_zero_fatal_violations")
    end
  end

  private

  def add_pending_human_criterion(directory)
    path = File.join(directory, "summary.json")
    summary = JSON.parse(File.read(path))
    summary["adoption_criteria"] = { "final_quality_decision_pending_human_evaluation" => true }
    File.write(path, JSON.pretty_generate(summary), mode: "w:UTF-8")
  end

  def prepare_preliminary_rows(directory)
    path = File.join(directory, "human_evaluation.csv")
    table = CSV.read(path, headers: true, encoding: "bom|utf-8")
    table.each_with_index do |row, index|
      if index.zero?
        row["distance_rating"] = "just_right"
        row["acceptable"] = "true"
        row["fatal_violation"] = "none"
        row["judge"] = "codex_preliminary"
        row["confidence"] = "low"
        row["reason"] = "人の確認が必要"
        row["needs_human_review"] = "true"
      else
        row["distance_rating"] = "just_right"
        row["acceptable"] = "true"
        row["fatal_violation"] = "none"
        row["judge"] = "codex_preliminary"
        row["confidence"] = "high"
        row["reason"] = "距離と余白が明確"
        row["needs_human_review"] = "false"
      end
    end
    CSV.open(path, "w:UTF-8", write_headers: true, headers: table.headers) do |csv|
      table.each { |row| csv << row }
    end
  end
end
