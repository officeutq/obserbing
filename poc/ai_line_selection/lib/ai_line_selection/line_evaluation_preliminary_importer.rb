# frozen_string_literal: true

require "csv"
require "json"

module AiLineSelection
  class LineEvaluationPreliminaryImporter
    CONFIDENCES = %w[high medium low].freeze

    def initialize(results_dir:, judgments_path:)
      @results_dir = File.expand_path(results_dir)
      @judgments_path = File.expand_path(judgments_path)
      @evaluation_path = File.join(@results_dir, LineEvaluationReviewer::EVALUATION_FILENAME)
    end

    def call
      rows = load_csv
      judgments = load_judgments
      validate_complete_set!(rows, judgments)
      by_id = judgments.to_h { |judgment| [judgment.fetch("blind_id"), validate_judgment!(judgment)] }
      rows.each do |row|
        judgment = by_id.fetch(row.fetch("blind_id"))
        row.merge!(
          "distance_rating" => judgment.fetch("distance_rating"),
          "acceptable" => judgment.fetch("acceptable").to_s,
          "fatal_violation" => judgment.fetch("fatal_violation"),
          "judge" => "codex_preliminary",
          "confidence" => judgment.fetch("confidence"),
          "reason" => judgment.fetch("reason"),
          "needs_human_review" => judgment.fetch("needs_human_review").to_s,
          "human_reviewed" => "false",
          "notes" => nil
        )
      end
      save(rows)
      {
        status: "imported",
        evaluated_outputs: rows.length,
        needs_human_review: judgments.count { |judgment| judgment.fetch("needs_human_review") },
        judge: "codex_preliminary",
        evaluation_file: @evaluation_path
      }
    end

    private

    def load_csv
      unless File.file?(@evaluation_path)
        raise DataError.new("Line evaluation review artifact is missing", details: { path: @evaluation_path })
      end

      CSV.read(@evaluation_path, headers: true, encoding: "bom|utf-8").map(&:to_h)
    end

    def load_judgments
      document = JSON.parse(File.read(@judgments_path, encoding: "UTF-8"))
      return document if document.is_a?(Array)

      raise DataError.new("Preliminary judgments must be a JSON array")
    rescue Errno::ENOENT => e
      raise DataError.new("Preliminary judgments file is missing", details: { path: e.path })
    rescue JSON::ParserError => e
      raise DataError.new("Preliminary judgments JSON is invalid", details: { error_class: e.class.name })
    end

    def validate_complete_set!(rows, judgments)
      expected = rows.map { |row| row.fetch("blind_id") }.sort
      actual = judgments.map { |judgment| judgment.fetch("blind_id") }.sort
      return if actual == expected && actual.uniq.length == actual.length

      raise DataError.new(
        "Preliminary judgments must cover every Blind ID exactly once",
        details: { expected_count: expected.length, actual_count: actual.length }
      )
    rescue KeyError
      raise DataError.new("Preliminary judgment is missing blind_id")
    end

    def validate_judgment!(judgment)
      distance = judgment.fetch("distance_rating")
      acceptable = judgment.fetch("acceptable")
      fatal = judgment.fetch("fatal_violation")
      confidence = judgment.fetch("confidence")
      reason = judgment.fetch("reason")
      needs_human = judgment.fetch("needs_human_review")
      valid = LineEvaluationReviewer::DISTANCES.include?(distance) && [true, false].include?(acceptable) &&
              fatal.is_a?(String) && !fatal.empty? && CONFIDENCES.include?(confidence) &&
              reason.is_a?(String) && !reason.empty? && [true, false].include?(needs_human)
      return judgment if valid

      raise DataError.new("Preliminary judgment is invalid", details: { blind_id: judgment["blind_id"] })
    rescue KeyError => e
      raise DataError.new(
        "Preliminary judgment is missing a required field",
        details: { blind_id: judgment["blind_id"], field: e.key }
      )
    end

    def save(rows)
      headers = rows.first&.keys || []
      CSV.open(@evaluation_path, "w:UTF-8", write_headers: true, headers: headers) do |csv|
        rows.each { |row| csv << row.values_at(*headers) }
      end
    end
  end
end
