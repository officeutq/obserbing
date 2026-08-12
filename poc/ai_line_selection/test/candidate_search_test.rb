# frozen_string_literal: true

require_relative "test_helper"

class CandidateSearchTest < Minitest::Test
  def test_excludes_non_approved_lines
    lines = [
      { "id" => "L001", "status" => "approved" },
      { "id" => "L002", "status" => "candidate" },
      { "id" => "L003", "status" => "retired" }
    ]
    vectors = [[1.0, 0.0], [1.0, 0.0], [1.0, 0.0]]

    result = AiLineSelection::CandidateSearch.new.search(
      query_vector: [1.0, 0.0],
      lines: lines,
      line_vectors: vectors,
      limit: 10
    )

    assert_equal ["L001"], result.map { |item| item.fetch("line").fetch("id") }
  end
end
