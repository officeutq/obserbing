# frozen_string_literal: true

require "digest"
require_relative "test_helper"

class AbstractionEmbeddingInputsTest < Minitest::Test
  PATH = File.join(AiLineSelection::ROOT, "data", "abstractions", "abstraction_only_v2_repetitions.yml")
  EVALUATION_PATH = File.join(AiLineSelection::ROOT, "data", "evaluations", "abstraction_embedding_v1.yml")

  def setup
    @document = YAML.safe_load_file(PATH, permitted_classes: [], aliases: false)
    @items = @document.fetch("items")
  end

  def test_contains_three_reviewed_repetitions_for_every_fixed_item
    assert_equal 156, @items.length
    assert_equal({ "entry" => 36, "line" => 120 }, @items.map { |item| item.fetch("source_type") }.tally)
    assert @items.all? { |item| item.fetch("review_status") == "codex_preliminary" }
    assert @items.all? { |item| item.fetch("usability").between?(2, 3) }
    assert @items.all? do |item|
      item.fetch("repetitions").map { |record| record.fetch("repetition") } == [1, 2, 3]
    end
  end

  def test_contains_only_short_abstractions_without_source_text_or_request_metadata
    assert @items.flat_map { |item| item.fetch("repetitions") }.all? do |record|
      record.fetch("abstraction").length.between?(2, 60)
    end
    refute @items.any? { |item| item.key?("body") || item.key?("text") || item.key?("request_id") || item.key?("usage") }
  end

  def test_records_fixed_versions_and_hashes
    assert_equal "abstraction-only-v2", @document.fetch("comparison_version")
    assert_equal 3, @document.fetch("repetitions")
    assert_equal 1, @document.fetch("line_index_repetition")
    assert_equal "8ca60da809022778f2f1474f2c20525748b1da7f90fec52d565a0ef58cd8e181",
                 @document.fetch("entry_data_sha256")
    assert_equal "c2c4814d0f159daf989a21e17413b008a822533ee5c843fbda00d658cfff4232",
                 @document.fetch("line_data_sha256")
    assert_match(/\A[0-9a-f]{64}\z/, Digest::SHA256.file(PATH).hexdigest)
  end

  def test_evaluation_artifact_keeps_failed_acceptance_visible
    evaluation = YAML.safe_load_file(EVALUATION_PATH, permitted_classes: [], aliases: false)

    assert_equal "not_eligible_for_ruby_selection_comparison", evaluation.fetch("status")
    assert_equal false, evaluation.dig("acceptance", "repeated_abstraction_top20_jaccard_at_least_0_80")
    assert_equal false, evaluation.dig("acceptance", "fatal_grounding_mismatch_zero_before_guard")
    assert_equal false, evaluation.dig("acceptance", "eligible_for_ruby_selection_comparison")
    assert_equal 1.0, evaluation.dig("blind_quality", "abstraction_only_v2", "entries_with_acceptable_candidate_rate")
    assert_equal 107.593, evaluation.dig("cost_jpy", "issue_total")
  end
end
