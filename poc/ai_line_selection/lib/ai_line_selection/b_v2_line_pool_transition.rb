# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2LinePoolTransition
    VERSION = "b-v2-line-pool-transition-v1"

    def initialize(configuration:)
      @configuration = configuration
    end

    def call(output_path: nil)
      decision = JSON.parse(File.read(evaluation_path("b_v2_gate_a_decision_v1.json"), encoding: "UTF-8"))
      criteria = YAML.safe_load_file(evaluation_path("b_v2_design_criteria_v2.yml"), permitted_classes: [], aliases: false)
      lines = DataLoader.new(@configuration).lines.select { |line| line.fetch("status") == "approved" }
      canonical = canonical_lines(lines)
      candidate = decision.fetch("outcome") == "architecture_candidate"
      result = {
        version: VERSION,
        issue: 49,
        created_at: "2026-08-13",
        gate_a: {
          outcome: decision.fetch("outcome"),
          decision_artifact: "b_v2_gate_a_decision_v1.json",
          criteria_id: decision.fetch("criteria_id"),
          criteria_sha256: decision.fetch("criteria_sha256")
        },
        transition: {
          line_pool_improvement_epic_allowed: candidate,
          line_pool_improvement_epic_created: false,
          gate_b_activated: candidate,
          decision: candidate ? "proceed_to_line_pool_improvement" : "do_not_proceed_to_line_pool_improvement",
          reason: candidate ?
            "Gate A architecture_candidate permits a separately versioned Line-pool-only Epic." :
            "Gate A architecture_rejected forbids treating this method as a fixed baseline for Line-pool improvement."
        },
        tested_configuration_snapshot: {
          status: candidate ? "gate_b_architecture_baseline" : "rejected_experiment_not_gate_b_baseline",
          profile_version: "b-v2-profile-primary-secondary-v1",
          embedding_version: "b-v2-openai-small-dual-cosine-v1",
          embedding_provider: "openai",
          embedding_model: "text-embedding-3-small",
          embedding_dimensions: 1536,
          normalization: "provider-normalized/cosine",
          a_min: 0.45,
          s_max: 0.55,
          top_n: 20,
          selector_version: "b-v2-selector-v1",
          selector_strategy: "uniform",
          selector_weight: nil,
          selector_seed_rule: "first_64_bits_of_sha256(base_seed|entry_id|repetition)",
          domain_taxonomy_version: "b-v2-profile-primary-secondary-v1",
          guard_policy_version: "b-v2-guard-policy-v1",
          approved_line_count: lines.length,
          approved_line_canonical_sha256: Digest::SHA256.hexdigest(canonical),
          approved_line_hash_algorithm: "Sort approved Lines by id; JSON.generate an array of objects with id,text,status keys in that order; SHA-256 UTF-8 bytes.",
          full_lines_file_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
          line_pool_changed_in_epic_40: false
        },
        gate_b: {
          evaluated: false,
          inactive_reason: candidate ? nil : "Gate A did not produce architecture_candidate.",
          criteria_preserved_for_future_design: criteria.fetch("gate_b")
        },
        future_selection_poc: {
          required_before_any_line_pool_improvement_epic: !candidate,
          reuse_current_rejected_version_as_baseline: false,
          minimum_conditions: [
            "Create a separately versioned selection hypothesis and pre-register criteria before results.",
            "Address acceptable improvement below the rejection floor and excess too-far/weak connections.",
            "Address all-three-repetition consistency and end-to-end p95.",
            "Keep selection-method changes separate from Line-pool changes.",
            "Use the eight human-review candidates as rubric evidence without retrofitting reflective-distance-v1."
          ],
          human_review_may_continue_as_evaluation_data: true,
          human_review_blocks_this_transition_decision: false
        },
        production_adoption_decided: false,
        line_pool_modified: false,
        external_api_calls: 0
      }
      write_json(output_path, result) if output_path
      result
    end

    private

    def canonical_lines(lines)
      normalized = lines.sort_by { |line| line.fetch("id") }.map do |line|
        { "id" => line.fetch("id"), "text" => line.fetch("text"), "status" => line.fetch("status") }
      end
      JSON.generate(normalized)
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def write_json(path, value)
      File.write(path, JSON.pretty_generate(value), mode: "w:UTF-8")
    end
  end
end
