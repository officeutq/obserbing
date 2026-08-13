# frozen_string_literal: true

require "digest"
require "yaml"
require_relative "test_helper"

class Bv2BandPassCriteriaTest < Minitest::Test
  def test_issue_43_freezes_band_pass_before_live_run_without_external_calls
    criteria = YAML.safe_load_file(
      File.join(configuration.root_dir, "data", "evaluations", "b_v2_band_pass_criteria_v1.yml"),
      permitted_classes: [], aliases: false
    )
    result_path = File.join(configuration.root_dir, "data", "evaluations", "b_v2_band_pass_offline_v1.json")
    result = JSON.parse(File.read(result_path, encoding: "UTF-8"))

    assert_equal "frozen_before_issue_46_live_results", criteria.fetch("status")
    assert_equal 20, criteria.dig("band_pass", "top_n")
    assert_equal 0.45, criteria.dig("band_pass", "abstraction_similarity_minimum")
    assert_equal 0.55, criteria.dig("band_pass", "surface_similarity_maximum")
    assert_equal "text-embedding-3-small", criteria.dig("embedding", "model")
    assert_equal 1536, criteria.dig("embedding", "dimensions")
    assert_equal "cosine", criteria.dig("embedding", "distance")
    assert_equal false, criteria.dig("band_pass", "single_monotonic_score_used")
    assert_equal 0, result.fetch("external_api_calls")
    assert_equal 0, result.fetch("embedding_api_calls")
    assert_equal 108, result.fetch("outcome_slots")
    canonical = Digest::SHA256.hexdigest(JSON.generate(result))
    assert_equal canonical, criteria.dig("offline_diagnostic", "source_canonical_json_sha256")
  end
end
