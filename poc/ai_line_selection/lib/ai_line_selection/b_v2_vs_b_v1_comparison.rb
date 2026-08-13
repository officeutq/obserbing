# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2VsBv1Comparison
    VERSION = "b-v2-vs-b-v1-comparison-v1"

    def initialize(configuration:)
      @configuration = configuration
    end

    def call(output_path: nil)
      b1 = b1_metrics
      b2 = b2_metrics
      result = {
        version: VERSION,
        issue: 47,
        created_at: "2026-08-13",
        external_api_calls: 0,
        comparison_scope: {
          b1: "abstraction-only-v1-diagnostic saved Issue #36/#38 outcomes",
          b2: "b-v2-integrated-live-v1 saved Issue #46 outcomes",
          same_entry_count: 36,
          same_repetitions: 3,
          same_outcome_denominator: 108,
          same_rubric: "reflective-distance-v1",
          current_approved_line_count: 96,
          current_line_pool_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
          simultaneous_head_to_head: false,
          caveat: "Runs were executed at different times with different chains; compare saved normalized outcomes rather than claiming a simultaneous controlled trial."
        },
        b1: b1,
        b2: b2,
        deltas: deltas(b1, b2),
        gate_b_not_evaluated: true,
        source_hashes: source_hashes
      }
      write_json(output_path, result) if output_path
      result
    end

    private

    def b1_metrics
      displays = CSV.read(evaluation_path("reflective_distance_display_pairs_v1.csv"), headers: true, encoding: "UTF-8")
                    .select { |row| row.fetch("dataset") == "abstraction_only_issue36" }
      labels = final_b1_labels
      outcomes = displays.map do |row|
        labels.fetch("#{row.fetch('entry_id')}/#{row.fetch('line_id')}").merge("entry_id" => row.fetch("entry_id"))
      end
      live = YAML.safe_load_file(evaluation_path("abstraction_only_integrated_live_v1.yml"), permitted_classes: [], aliases: false)
      metrics(outcomes).merge(
        "method" => "abstraction-only-v1-diagnostic",
        "semantic_silence_count" => live.dig("results", "errors_and_silence", "semantic_silence_count"),
        "semantic_silence_rate" => ratio(live.dig("results", "errors_and_silence", "semantic_silence_count"), outcomes.length),
        "safety_overblock_count" => live.dig("results", "safety", "existing_normal_overblock_count"),
        "technical_error_count" => live.dig("results", "errors_and_silence", "completed_record_technical_error_count"),
        "p95_seconds" => (live.dig("results", "latency_ms", "end_to_end_p95") / 1000.0).round(5),
        "post_cost_jpy" => live.dig("api_and_cost", "normal_flow_cost_per_post_jpy"),
        "normal_external_requests_per_post" => 3,
        "realtime_line_evaluation_llm_calls" => 0,
        "unresolved_low_confidence_count" => 0
      )
    end

    def b2_metrics
      evaluation = JSON.parse(File.read(evaluation_path("b_v2_integrated_evaluation_v1.json"), encoding: "UTF-8"))
      quality = evaluation.fetch("quality")
      {
        "method" => "b-v2-integrated-live-v1",
        "outcome_count" => quality.fetch("denominator"),
        "acceptable_count" => quality.fetch("acceptable_count"),
        "acceptable_rate" => quality.fetch("acceptable_rate"),
        "direct_restatement_too_close_count" => quality.fetch("direct_restatement_too_close_count"),
        "too_far_plus_unrelated_count" => quality.fetch("too_far_plus_unrelated_count"),
        "unrelated_count" => quality.fetch("unrelated_count"),
        "analogical_transfer_count" => quality.fetch("analogical_transfer_count"),
        "acceptable_analogical_transfer_count" => quality.fetch("acceptable_analogical_transfer_count"),
        "acceptable_analogical_transfer_rate" => ratio(quality.fetch("acceptable_analogical_transfer_count"), quality.fetch("analogical_transfer_count")),
        "all_three_repetitions_acceptable_entry_count" => quality.fetch("all_three_repetitions_acceptable_entry_count"),
        "all_three_repetitions_acceptable_entry_rate" => quality.fetch("all_three_repetitions_acceptable_entry_rate"),
        "user_fact_assertion_count" => quality.fetch("user_fact_assertion_count"),
        "explicit_contradiction_count" => quality.fetch("explicit_contradiction_count"),
        "advice_or_diagnosis_count" => quality.fetch("advice_or_diagnosis_count"),
        "semantic_silence_count" => quality.fetch("semantic_silence_count"),
        "semantic_silence_rate" => evaluation.dig("selection", "semantic_silence_rate"),
        "safety_overblock_count" => evaluation.dig("safety", "overblock_count"),
        "technical_error_count" => evaluation.fetch("technical_error_count"),
        "p95_seconds" => (evaluation.dig("latency_ms", "p95") / 1000.0).round(5),
        "post_cost_jpy" => evaluation.dig("api_and_cost", "cost_per_post_jpy"),
        "normal_external_requests_per_post" => evaluation.dig("api_and_cost", "normal_external_requests_per_post"),
        "realtime_line_evaluation_llm_calls" => evaluation.dig("selection", "realtime_line_evaluation_llm_calls"),
        "unresolved_low_confidence_count" => quality.fetch("unresolved_low_confidence_occurrence_count")
      }
    end

    def metrics(outcomes)
      all_three = outcomes.group_by { |row| row.fetch("entry_id") }.count { |_entry, rows| rows.length == 3 && rows.all? { |row| row.fetch("acceptable") } }
      analogical = outcomes.count { |row| row.fetch("relation_type") == "analogical_transfer" }
      acceptable_analogical = outcomes.count { |row| row.fetch("acceptable") && row.fetch("relation_type") == "analogical_transfer" }
      {
        "outcome_count" => outcomes.length,
        "acceptable_count" => outcomes.count { |row| row.fetch("acceptable") },
        "acceptable_rate" => ratio(outcomes.count { |row| row.fetch("acceptable") }, outcomes.length),
        "direct_restatement_too_close_count" => outcomes.count { |row| row.fetch("relation_type") == "direct_restatement" },
        "too_far_plus_unrelated_count" => outcomes.count { |row| %w[weak_connection unrelated].include?(row.fetch("relation_type")) },
        "unrelated_count" => outcomes.count { |row| row.fetch("relation_type") == "unrelated" },
        "analogical_transfer_count" => analogical,
        "acceptable_analogical_transfer_count" => acceptable_analogical,
        "acceptable_analogical_transfer_rate" => ratio(acceptable_analogical, analogical),
        "all_three_repetitions_acceptable_entry_count" => all_three,
        "all_three_repetitions_acceptable_entry_rate" => ratio(all_three, outcomes.map { |row| row.fetch("entry_id") }.uniq.length),
        "user_fact_assertion_count" => outcomes.count { |row| row.fetch("user_fact_assertion") },
        "explicit_contradiction_count" => outcomes.count { |row| row.fetch("explicit_contradiction") },
        "advice_or_diagnosis_count" => outcomes.count { |row| row.fetch("advice_or_diagnosis") }
      }
    end

    def final_b1_labels
      labels = CSV.read(evaluation_path("reflective_distance_codex_judgments_v1.csv"), headers: true, encoding: "UTF-8").to_h do |row|
        [row.fetch("pair_id"), label_from(row.to_h)]
      end
      human = YAML.safe_load_file(evaluation_path("reflective_distance_human_review_v1.yml"), permitted_classes: [], aliases: false)
      human.fetch("reviews").each do |review|
        labels[review.fetch("pair_id")] = label_from(review.fetch("final_labels"))
      end
      labels
    end

    def label_from(row)
      row = row.transform_keys(&:to_s)
      {
        "acceptable" => boolean(row.fetch("acceptable")),
        "relation_type" => row.fetch("relation_type"),
        "user_fact_assertion" => boolean(row.fetch("user_fact_assertion")),
        "explicit_contradiction" => boolean(row.fetch("explicit_contradiction")),
        "advice_or_diagnosis" => boolean(row.fetch("advice_or_diagnosis"))
      }
    end

    def boolean(value)
      value == true || value == "true"
    end

    def deltas(b1, b2)
      {
        "acceptable_count" => b2.fetch("acceptable_count") - b1.fetch("acceptable_count"),
        "acceptable_percentage_points" => ((b2.fetch("acceptable_rate") - b1.fetch("acceptable_rate")) * 100).round(2),
        "direct_restatement_too_close_count" => b2.fetch("direct_restatement_too_close_count") - b1.fetch("direct_restatement_too_close_count"),
        "direct_restatement_too_close_reduction_rate" => ratio(b1.fetch("direct_restatement_too_close_count") - b2.fetch("direct_restatement_too_close_count"), b1.fetch("direct_restatement_too_close_count")),
        "too_far_plus_unrelated_count" => b2.fetch("too_far_plus_unrelated_count") - b1.fetch("too_far_plus_unrelated_count"),
        "too_far_plus_unrelated_percentage_points" => ((ratio(b2.fetch("too_far_plus_unrelated_count"), b2.fetch("outcome_count")) - ratio(b1.fetch("too_far_plus_unrelated_count"), b1.fetch("outcome_count"))) * 100).round(2),
        "unrelated_count" => b2.fetch("unrelated_count") - b1.fetch("unrelated_count"),
        "acceptable_analogical_transfer_count" => b2.fetch("acceptable_analogical_transfer_count") - b1.fetch("acceptable_analogical_transfer_count"),
        "acceptable_analogical_transfer_retention_rate" => ratio(b2.fetch("acceptable_analogical_transfer_count"), b1.fetch("acceptable_analogical_transfer_count")),
        "all_three_acceptable_entry_count" => b2.fetch("all_three_repetitions_acceptable_entry_count") - b1.fetch("all_three_repetitions_acceptable_entry_count"),
        "p95_seconds" => (b2.fetch("p95_seconds") - b1.fetch("p95_seconds")).round(5),
        "post_cost_jpy" => (b2.fetch("post_cost_jpy") - b1.fetch("post_cost_jpy")).round(4)
      }
    end

    def source_hashes
      %w[
        reflective_distance_display_pairs_v1.csv reflective_distance_codex_judgments_v1.csv
        reflective_distance_human_review_v1.yml abstraction_only_integrated_live_v1.yml
        b_v2_integrated_evaluation_v1.json b_v2_integrated_evaluated_outcomes_v1.jsonl
      ].to_h { |filename| [filename, Digest::SHA256.file(evaluation_path(filename)).hexdigest] }
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def write_json(path, value)
      File.write(path, JSON.pretty_generate(value), mode: "w:UTF-8")
    end
  end
end
