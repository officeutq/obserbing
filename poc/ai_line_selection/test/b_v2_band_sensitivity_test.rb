# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "digest"
require "json"
require "yaml"

class Bv2BandSensitivityTest < Minitest::Test
  ARTIFACT_DIR = File.expand_path("../data/evaluations/b_v2_band_sensitivity_v1", __dir__)

  def test_grid_is_the_frozen_825_setting_uniform_sweep
    assert_equal 11, AiLineSelection::Bv2BandSensitivity::A_MINS.length
    assert_equal 15, AiLineSelection::Bv2BandSensitivity::S_MAXES.length
    assert_equal [5, 10, 20, 40, 96], AiLineSelection::Bv2BandSensitivity::TOP_NS
    assert_equal 825,
                 AiLineSelection::Bv2BandSensitivity::A_MINS.length *
                 AiLineSelection::Bv2BandSensitivity::S_MAXES.length *
                 AiLineSelection::Bv2BandSensitivity::TOP_NS.length
    assert_equal 0.35, AiLineSelection::Bv2BandSensitivity::A_MINS.first
    assert_equal 0.60, AiLineSelection::Bv2BandSensitivity::A_MINS.last
    assert_equal 0.35, AiLineSelection::Bv2BandSensitivity::S_MAXES.first
    assert_equal 0.70, AiLineSelection::Bv2BandSensitivity::S_MAXES.last
  end

  def test_mechanical_artifacts_are_complete_and_reproduce_issue_46
    manifest = JSON.parse(File.read(artifact("b_v2_band_sensitivity_manifest_v1.json"), encoding: "UTF-8"))
    pair_rows = CSV.read(artifact("b_v2_band_sensitivity_pair_similarities_v1.csv"), headers: true, encoding: "UTF-8")
    selection_rows = CSV.read(artifact("b_v2_band_sensitivity_selections_v1.csv"), headers: true, encoding: "UTF-8")
    mechanical_rows = File.readlines(artifact("b_v2_band_sensitivity_mechanical_v1.jsonl"), encoding: "UTF-8")

    assert_equal 10_368, pair_rows.length
    assert_equal 10_368, pair_rows.map { |row| row.values_at("entry_id", "repetition", "line_id") }.uniq.length
    assert_equal 89_100, selection_rows.length
    assert_equal 825, mechanical_rows.length
    assert_equal true, manifest.dig("current_setting_reproduction", "exact")
    assert_equal 0, manifest.dig("current_setting_reproduction", "mismatch_count")
    assert_equal 105, manifest.dig("current_setting_reproduction", "selected_count")
    assert_equal 3, manifest.dig("current_setting_reproduction", "semantic_silence_count")
    assert_equal "f36a277daf2d9cf0d6b4d5bfb602f7070387f889d43d3247516f294f5841d2fa",
                 manifest.dig("source_hashes", "issue_46_line_index_sha256")
    assert_equal false, manifest.fetch("network_call_performed")
    assert_equal 0, manifest.fetch("external_api_calls")
    assert_equal "uniform", manifest.fetch("selector_strategy")
    assert_equal false, manifest.dig("separation_of_evidence", "similarity_used_as_quality_label")
  end

  def test_quality_judgments_are_complete_and_codex_additions_are_provisional
    rows = CSV.read(artifact("b_v2_band_sensitivity_pair_judgments_v1.csv"), headers: true, encoding: "UTF-8")
    codex = rows.select { |row| row.fetch("label_source") == "b_v2_band_sensitivity_codex_review_v1" }
    review = YAML.safe_load_file(
      File.expand_path("../data/evaluations/b_v2_band_sensitivity_codex_review_v1.yml", __dir__),
      permitted_classes: [], aliases: false
    )

    assert_equal 587, rows.length
    assert rows.none? { |row| row.fetch("acceptable").empty? }
    assert_equal 444, codex.length
    assert_equal 64, codex.count { |row| row.fetch("confidence") == "low" }
    assert codex.all? { |row| row.fetch("judge") == "codex_provisional" }
    assert codex.all? { |row| row.fetch("provisional") == "true" }
    assert_equal "reflective-distance-v1", review.fetch("rubric")
    assert_equal 0, review.fetch("external_api_calls")
  end

  private

  def artifact(filename)
    File.join(ARTIFACT_DIR, filename)
  end
end
