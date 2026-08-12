# frozen_string_literal: true

require_relative "test_helper"

class DataLoaderTest < Minitest::Test
  def test_dataset_counts_are_fixed
    assert_equal 36, data_loader.entries.length
    assert_equal 120, data_loader.lines.length
    assert_equal 12, data_loader.safety_cases.length
  end

  def test_line_states_cover_search_and_non_search_records
    counts = data_loader.lines.map { |line| line.fetch("status") }.tally

    assert_equal 96, counts.fetch("approved")
    assert_equal 12, counts.fetch("candidate")
    assert_equal 12, counts.fetch("retired")
  end

  def test_all_data_is_marked_synthetic
    assert data_loader.entries.all? { |entry| entry.fetch("body").is_a?(String) }
    assert data_loader.lines.all? { |line| line.fetch("source") == "synthetic" }
  end
end
