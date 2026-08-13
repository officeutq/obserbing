# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class CandidateQualityComparisonTest < Minitest::Test
  def test_plan_counts_blind_top_five_evaluations_without_network
    Dir.mktmpdir do |directory|
      AiLineSelection::AbstractionEmbeddingComparison.new(configuration: configuration).call(
        provider: "fixture",
        output_dir: directory
      )
      comparison = AiLineSelection::CandidateQualityComparison.new(
        configuration: configuration,
        results_dir: directory
      )
      plan = comparison.plan(provider: "openai")

      assert_equal false, plan.fetch(:network_call_performed)
      assert_equal 36, plan.fetch(:total_requests)
      assert_equal 72, plan.fetch(:maximum_requests_with_retries)
      assert_equal 108, plan.fetch(:blind_set_count)
      assert_equal 540, plan.fetch(:candidate_evaluations)
      assert_equal true, plan.fetch(:source_texts_blinded_to_mode)
      assert_raises(AiLineSelection::ExternalApiDisabledError) { comparison.call(provider: "openai") }
    end
  end
end
