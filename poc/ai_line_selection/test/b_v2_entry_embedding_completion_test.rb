# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "fileutils"
require "json"
require "tmpdir"

class Bv2EntryEmbeddingCompletionTest < Minitest::Test
  def setup
    @results = Dir.mktmpdir("b_v2_entry_embedding_completion")
    vector = [1.0] + Array.new(1535, 0.0)
    index = {
      "line_ids" => (1..96).map { |number| format("L%03d", number) },
      "abstraction_vectors" => Array.new(96) { vector },
      "surface_vectors" => Array.new(96) { vector },
      "phase" => {}
    }
    File.write(File.join(@results, "line_index.json"), JSON.generate(index), mode: "w:UTF-8")
    outputs = configuration.then { |config| AiLineSelection::DataLoader.new(config).entries }.flat_map do |entry|
      (1..3).map do |repetition|
        {
          "entry_id" => entry.fetch("id"), "repetition" => repetition,
          "safety_classification" => "normal", "abstraction" => "fixed #{entry.fetch('id')} #{repetition}"
        }
      end
    end
    File.write(
      File.join(@results, "provider_outputs.jsonl"),
      outputs.map { |row| JSON.generate(row) }.join("\n") + "\n",
      mode: "w:UTF-8"
    )
    @line_hash = Digest::SHA256.file(File.join(@results, "line_index.json")).hexdigest
  end

  def teardown
    FileUtils.remove_entry(@results) if @results && Dir.exist?(@results)
  end

  def test_plan_verifies_sources_and_batches_all_missing_entry_inputs_once
    plan = AiLineSelection::Bv2EntryEmbeddingCompletion.new(
      configuration: configuration,
      issue_46_results_dir: @results,
      expected_line_index_sha256: @line_hash
    ).plan

    assert_equal false, plan.fetch(:network_call_performed)
    assert_equal @line_hash, plan.fetch(:line_index_sha256)
    assert_equal true, plan.fetch(:line_index_hash_matches)
    assert_equal 36, plan.fetch(:raw_entry_count)
    assert_equal 108, plan.fetch(:abstraction_outcome_count)
    assert_equal 144, plan.fetch(:total_embedding_input_count)
    assert_equal 1, plan.fetch(:normal_api_requests)
    assert_equal 2, plan.fetch(:maximum_api_requests_with_retry)
    assert_equal "text-embedding-3-small", plan.fetch(:model)
    assert_equal 1536, plan.fetch(:dimensions)
    assert_equal 10_368, plan.fetch(:expected_pair_similarity_rows)
    assert_operator plan.fetch(:conservative_cost_jpy_including_retry), :<, 100.0
    assert_equal ["embedding"], plan.fetch(:allowed_external_operations)
    assert_equal false, plan.fetch(:line_embedding_regeneration_supported)
  end

  def test_external_run_requires_explicit_permission
    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::Bv2EntryEmbeddingCompletion.new(
        configuration: configuration,
        issue_46_results_dir: @results,
        expected_line_index_sha256: @line_hash
      ).call(output_dir: File.join(configuration.path(:results), "should_not_exist_band_sensitivity"))
    end
    assert_equal "external_api_disabled", error.code
  end
end
