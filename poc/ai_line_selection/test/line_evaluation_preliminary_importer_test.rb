# frozen_string_literal: true

require "csv"
require "tmpdir"
require_relative "test_helper"

class LineEvaluationPreliminaryImporterTest < Minitest::Test
  def test_imports_complete_codex_preliminary_judgments
    Dir.mktmpdir do |directory|
      AiLineSelection::LineEvaluationComparison.new(configuration: configuration).call(
        providers: ["fixture"],
        repetitions: 1,
        entry_ids: %w[E001 E002],
        embedding_provider: "fixture",
        output_dir: directory
      )
      evaluation_path = File.join(directory, "human_evaluation.csv")
      rows = CSV.read(evaluation_path, headers: true, encoding: "bom|utf-8")
      judgments = rows.each_with_index.map do |row, index|
        {
          blind_id: row.fetch("blind_id"),
          distance_rating: "just_right",
          acceptable: true,
          fatal_violation: "none",
          confidence: index.zero? ? "low" : "high",
          reason: "test judgment",
          needs_human_review: index.zero?
        }
      end
      judgments_path = File.join(directory, "preliminary.json")
      File.write(judgments_path, JSON.pretty_generate(judgments), mode: "w:UTF-8")

      result = AiLineSelection::LineEvaluationPreliminaryImporter.new(
        results_dir: directory,
        judgments_path: judgments_path
      ).call

      assert_equal "imported", result.fetch(:status)
      assert_equal 2, result.fetch(:evaluated_outputs)
      assert_equal 1, result.fetch(:needs_human_review)
      imported = CSV.read(evaluation_path, headers: true, encoding: "bom|utf-8")
      assert imported.all? { |row| row.fetch("judge") == "codex_preliminary" }
      assert_equal 1, imported.count { |row| row.fetch("needs_human_review") == "true" }
    end
  end
end
