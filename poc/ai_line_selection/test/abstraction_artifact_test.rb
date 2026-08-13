# frozen_string_literal: true

require "digest"
require_relative "test_helper"

class AbstractionArtifactTest < Minitest::Test
  ARTIFACT_PATH = File.join(AiLineSelection::ROOT, "data", "abstractions", "abstraction_only_v2.yml")

  def setup
    @document = YAML.safe_load_file(ARTIFACT_PATH, permitted_classes: [], aliases: false)
    @items = @document.fetch("abstractions")
    @data = AiLineSelection::DataLoader.new(configuration)
  end

  def test_artifact_preserves_all_source_ids_and_statuses
    expected_ids = @data.entries.map { |item| item.fetch("id") } + @data.lines.map { |item| item.fetch("id") }

    assert_equal 156, @items.length
    assert_equal expected_ids, @items.map { |item| item.fetch("id") }
    assert_equal 156, @items.map { |item| item.fetch("id") }.uniq.length
    assert_equal({ "entry" => 36, "line" => 120 }, @items.map { |item| item.fetch("source_type") }.tally)
    assert_equal(
      { "evaluation" => 36, "approved" => 96, "candidate" => 12, "retired" => 12 },
      @items.map { |item| item.fetch("source_status") }.tally
    )
  end

  def test_artifact_contains_only_reviewed_short_abstractions
    assert @items.all? { |item| item.fetch("abstraction").length.between?(2, 60) }
    assert @items.all? { |item| item.fetch("review_status") == "codex_preliminary" }
    assert @items.all? { |item| item.fetch("usability").between?(2, 3) }
    refute @items.any? { |item| item.key?("themes") || item.key?("structure") || item.key?("text") }
  end

  def test_artifact_records_fixed_versions_and_hashes
    assert_equal "abstraction-only-v2", @document.fetch("comparison_version")
    assert_equal "gpt-5.6-terra", @document.fetch("model")
    assert_equal "codex_preliminary", @document.dig("review", "judge")
    assert_equal 0, @document.dig("review", "human_review_required_count")
    assert_equal "8ca60da809022778f2f1474f2c20525748b1da7f90fec52d565a0ef58cd8e181",
                 @document.fetch("entry_data_sha256")
    assert_equal "c2c4814d0f159daf989a21e17413b008a822533ee5c843fbda00d658cfff4232",
                 @document.fetch("line_data_sha256")
    assert_equal "2617134aa9f09ed08f594983910528112e462747d92bfaf3e697e420cf393c08",
                 Digest::SHA256.file(ARTIFACT_PATH).hexdigest
  end
end
