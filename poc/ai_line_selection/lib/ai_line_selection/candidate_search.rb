# frozen_string_literal: true

module AiLineSelection
  class CandidateSearch
    def search(query_vector:, lines:, line_vectors:, limit:)
      unless lines.length == line_vectors.length
        raise DataError.new(
          "Line and vector counts must match",
          details: { lines: lines.length, vectors: line_vectors.length }
        )
      end

      lines.zip(line_vectors).filter_map do |line, vector|
        next unless line.fetch("status") == "approved"

        { "line" => line, "similarity" => cosine_similarity(query_vector, vector) }
      end.sort_by { |candidate| [-candidate.fetch("similarity"), candidate.fetch("line").fetch("id")] }
        .first(limit)
    end

    private

    def cosine_similarity(left, right)
      unless left.length == right.length
        raise DataError.new(
          "Embedding dimensions must match",
          details: { left: left.length, right: right.length }
        )
      end

      dot = left.zip(right).sum { |a, b| a * b }
      left_size = Math.sqrt(left.sum { |value| value * value })
      right_size = Math.sqrt(right.sum { |value| value * value })
      return 0.0 if left_size.zero? || right_size.zero?

      (dot / (left_size * right_size)).round(8)
    end
  end
end
