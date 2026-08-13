# frozen_string_literal: true

require "csv"
require "tmpdir"
require_relative "test_helper"

class Bv2BandPassOfflineTest < Minitest::Test
  def test_saved_artifact_comparison_performs_no_network_call
    abstraction_dir = File.join(configuration.path(:results), "abstraction_embedding_20260813T011138Z_8550")
    surface_dir = File.join(configuration.path(:results), "embedding_20260812T081729Z_a63c")
    skip "saved diagnostic artifacts are unavailable" unless Dir.exist?(abstraction_dir) && Dir.exist?(surface_dir)

    Dir.mktmpdir do |directory|
      output = File.join(directory, "result.json")
      result = AiLineSelection::Bv2BandPassOffline.new(
        configuration: configuration,
        abstraction_results_dir: abstraction_dir,
        surface_results_dir: surface_dir
      ).call(output_path: output)

      assert_equal false, result.fetch(:network_call_performed)
      assert_equal 0, result.fetch(:external_api_calls)
      assert_equal 0, result.fetch(:embedding_api_calls)
      assert_equal 108, result.fetch(:outcome_slots)
      assert_equal 36, result.fetch(:entry_count)
      assert_equal 96, result.fetch(:approved_line_count)
      assert_equal 75, result.fetch(:grid).length
      assert File.exist?(output)
      assert_equal true, result.dig(:surface_proxy, :not_interchangeable_with_provider_embedding_cosine)
    end
  end
end
