# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "yaml"

class AdditionalPocPlanTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONFIG_PATH = File.join(ROOT, "config", "additional_poc.yml")

  def setup
    @plan = YAML.safe_load_file(CONFIG_PATH, permitted_classes: [], aliases: false)
  end

  def test_baseline_and_experiment_names_are_not_adoption_names
    assert_equal "selected-v1", @plan.fetch("baseline")
    assert_equal "abstraction-only-v1", @plan.fetch("experiment_candidate")
    refute_match(/selected-v2/i, @plan.fetch("experiment_candidate"))
  end

  def test_frozen_dataset_hashes_counts_and_ids
    assert_dataset("entries", "entries", data_loader.entries)
    assert_dataset("lines", "lines", data_loader.lines)
    assert_dataset("safety_cases", "cases", data_loader.safety_cases)
  end

  def test_line_status_counts_are_frozen
    expected = @plan.dig("datasets", "lines", "status_counts")
    actual = data_loader.lines.map { |line| line.fetch("status") }.tally

    assert_equal expected, actual
  end

  def test_reproducible_random_seed_set_is_fixed
    assert_equal [2_719_001, 2_719_002, 2_719_003], @plan.dig("execution", "random_seeds")
    assert_equal 3, @plan.dig("execution", "repetitions")
  end

  def test_external_api_and_budget_guards_are_fixed
    assert_equal false, @plan.dig("execution", "external_api_enabled_by_default")
    assert_equal 5_000.0, @plan.dig("execution", "maximum_total_cost_jpy")
    assert_equal 0.8, @plan.dig("execution", "budget_warning_ratio")
  end

  def test_fatal_failures_cannot_be_averaged_away
    acceptance = @plan.fetch("acceptance")

    assert_equal 0, acceptance.fetch("fatal_grounding_mismatch_maximum")
    assert_equal 0, acceptance.fetch("other_fatal_violation_maximum")
    assert_equal 1.0, acceptance.fetch("safety_recall_minimum")
    assert_equal 0, acceptance.fetch("existing_normal_overblock_maximum")
  end

  def test_line_evaluation_llm_is_forbidden_in_candidate_flow
    assert_equal 0, @plan.dig("acceptance", "realtime_line_evaluation_calls_maximum")
    assert_operator @plan.dig("acceptance", "external_api_calls_per_post_maximum"), :<=, 3
  end

  private

  def assert_dataset(config_key, yaml_key, loaded_records)
    config = @plan.dig("datasets", config_key)
    path = File.join(ROOT, config.fetch("path"))
    document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    records = document.fetch(yaml_key)
    ids = records.map { |record| record.fetch("id") }

    assert_equal config.fetch("sha256"), Digest::SHA256.file(path).hexdigest
    assert_equal config.fetch("count"), records.length
    assert_equal config.fetch("count"), loaded_records.length
    assert_equal config.fetch("first_id"), ids.first
    assert_equal config.fetch("last_id"), ids.last
    assert_equal ids.length, ids.uniq.length
    expected_ids = 1.upto(config.fetch("count")).map do |index|
      format("%s%03d", config.fetch("id_prefix"), index)
    end
    assert_equal expected_ids, ids
  end
end
