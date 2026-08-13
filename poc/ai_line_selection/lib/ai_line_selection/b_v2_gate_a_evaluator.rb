# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2GateAEvaluator
    VERSION = "b-v2-gate-a-decision-v1"

    def initialize(configuration:)
      @configuration = configuration
    end

    def call(output_path: nil)
      criteria = YAML.safe_load_file(criteria_path, permitted_classes: [], aliases: false)
      comparison = JSON.parse(File.read(evaluation_path("b_v2_vs_b_v1_comparison_v1.json"), encoding: "UTF-8"))
      integrated = JSON.parse(File.read(evaluation_path("b_v2_integrated_evaluation_v1.json"), encoding: "UTF-8"))
      gate = criteria.fetch("gate_a")
      b1 = comparison.fetch("b1")
      b2 = comparison.fetch("b2")
      delta = comparison.fetch("deltas")
      conditions = candidate_conditions(gate, b1, b2, delta)
      rejection = rejection_floors(gate, b1, b2, delta, conditions)
      outcome = if conditions.all? { |condition| condition.fetch(:pass) }
                  "architecture_candidate"
                elsif rejection.any? { |floor| floor.fetch(:triggered) }
                  "architecture_rejected"
                else
                  "further_selection_poc_required"
                end
      sensitivity = low_confidence_sensitivity(integrated, gate)
      result = {
        version: VERSION,
        issue: 48,
        created_at: "2026-08-13",
        criteria_id: criteria.fetch("criteria_id"),
        design_id: criteria.fetch("design_id"),
        criteria_sha256: Digest::SHA256.file(criteria_path).hexdigest,
        baseline: gate.fetch("baseline"),
        candidate_conditions: conditions,
        candidate_condition_pass_count: conditions.count { |condition| condition.fetch(:pass) },
        candidate_condition_total_count: conditions.length,
        all_candidate_conditions_pass: conditions.all? { |condition| condition.fetch(:pass) },
        rejection_floors: rejection,
        rejection_floor_triggered: rejection.any? { |floor| floor.fetch(:triggered) },
        low_confidence_sensitivity: sensitivity,
        outcome: outcome,
        outcome_reason: outcome_reason(outcome, conditions, rejection, sensitivity),
        production_adoption_decided: false,
        gate_b_evaluated: false,
        criteria_or_threshold_changed_after_results: false,
        line_pool_changed: false,
        external_api_calls: 0,
        sources: {
          comparison: "b_v2_vs_b_v1_comparison_v1.json",
          integrated_evaluation: "b_v2_integrated_evaluation_v1.json",
          fixed_criteria: "b_v2_design_criteria_v2.yml"
        }
      }
      write_json(output_path, result) if output_path
      result
    end

    private

    def candidate_conditions(gate, b1, b2, delta)
      required = gate.fetch("architecture_candidate_requires_all")
      acceptable = required.fetch("acceptable_outcome")
      close = required.fetch("direct_restatement_too_close")
      far = required.fetch("too_far_plus_unrelated")
      unrelated = required.fetch("unrelated")
      analogical = required.fetch("acceptable_analogical_transfer")
      repetitions = required.fetch("all_three_repetitions_acceptable_entry")
      silence = required.fetch("semantic_silence")
      zero = required.fetch("required_zero_counts")
      operations = required.fetch("operations")
      [
        condition("acceptable_rate", b2.fetch("acceptable_rate"), ">=", acceptable.fetch("minimum_rate")),
        condition("acceptable_count", b2.fetch("acceptable_count"), ">=", acceptable.fetch("minimum_count_for_108")),
        condition("acceptable_improvement_points", delta.fetch("acceptable_percentage_points"), ">=", acceptable.fetch("minimum_improvement_points_over_baseline")),
        condition("too_close_reduction_rate", delta.fetch("direct_restatement_too_close_reduction_rate"), ">=", close.fetch("minimum_reduction_rate_from_baseline")),
        condition("too_close_count", b2.fetch("direct_restatement_too_close_count"), "<=", close.fetch("maximum_count_for_108")),
        condition("too_far_plus_unrelated_increase_points", delta.fetch("too_far_plus_unrelated_percentage_points"), "<=", far.fetch("maximum_increase_points_over_baseline")),
        condition("too_far_plus_unrelated_count", b2.fetch("too_far_plus_unrelated_count"), "<=", far.fetch("maximum_count_for_108")),
        condition("unrelated_count", b2.fetch("unrelated_count"), "<=", unrelated.fetch("maximum_count_for_108")),
        condition("acceptable_analogical_retention_rate", delta.fetch("acceptable_analogical_transfer_retention_rate"), ">=", analogical.fetch("minimum_retention_rate_from_baseline")),
        condition("acceptable_analogical_count", b2.fetch("acceptable_analogical_transfer_count"), ">=", analogical.fetch("minimum_count_for_108")),
        condition("acceptable_rate_within_analogical", b2.fetch("acceptable_analogical_transfer_rate"), ">=", analogical.fetch("minimum_acceptable_rate_within_relation")),
        condition("all_three_acceptable_entry_rate", b2.fetch("all_three_repetitions_acceptable_entry_rate"), ">=", repetitions.fetch("minimum_rate")),
        condition("all_three_acceptable_entry_count", b2.fetch("all_three_repetitions_acceptable_entry_count"), ">=", repetitions.fetch("minimum_count_for_36")),
        condition("semantic_silence_rate", b2.fetch("semantic_silence_rate"), "<=", silence.fetch("maximum_rate")),
        condition("semantic_silence_count", b2.fetch("semantic_silence_count"), "<=", silence.fetch("maximum_count_for_108")),
        condition("user_fact_assertion_count", b2.fetch("user_fact_assertion_count"), "==", zero.fetch("user_fact_assertion")),
        condition("explicit_contradiction_count", b2.fetch("explicit_contradiction_count"), "==", zero.fetch("explicit_contradiction")),
        condition("advice_or_diagnosis_count", b2.fetch("advice_or_diagnosis_count"), "==", zero.fetch("advice_or_diagnosis")),
        condition("unresolved_low_confidence_count", b2.fetch("unresolved_low_confidence_count"), "==", zero.fetch("unresolved_low_confidence")),
        condition("existing_normal_entry_safety_overblock_count", b2.fetch("safety_overblock_count"), "==", zero.fetch("existing_normal_entry_safety_overblock")),
        condition("completed_flow_technical_error_count", b2.fetch("technical_error_count"), "==", zero.fetch("completed_flow_technical_errors")),
        condition("end_to_end_p95_seconds", b2.fetch("p95_seconds"), "<=", operations.fetch("end_to_end_p95_seconds_maximum")),
        condition("post_cost_jpy", b2.fetch("post_cost_jpy"), "<=", operations.fetch("post_cost_jpy_maximum")),
        condition("normal_external_request_count", b2.fetch("normal_external_requests_per_post"), "<=", operations.fetch("normal_external_request_count_maximum")),
        condition("realtime_line_evaluation_llm_calls", b2.fetch("realtime_line_evaluation_llm_calls"), "==", operations.fetch("realtime_line_evaluation_llm_calls"))
      ]
    end

    def rejection_floors(gate, _b1, b2, delta, conditions)
      floors = gate.fetch("rejection_floors")
      safety_policy_count = %w[user_fact_assertion_count explicit_contradiction_count advice_or_diagnosis_count existing_normal_entry_safety_overblock_count completed_flow_technical_error_count]
                            .sum { |id| conditions.find { |item| item.fetch(:id) == id }.fetch(:observed) }
      operational_fail = %w[end_to_end_p95_seconds post_cost_jpy normal_external_request_count realtime_line_evaluation_llm_calls]
                         .any? { |id| !conditions.find { |item| item.fetch(:id) == id }.fetch(:pass) }
      [
        floor("required_safety_or_policy_count_above_zero", safety_policy_count.positive?, safety_policy_count, floors.fetch("any_required_safety_or_policy_count_above_zero")),
        floor("operational_budget_violation_on_valid_run", operational_fail, operational_fail, floors.fetch("any_operational_budget_violation_on_valid_run")),
        floor("acceptable_improvement_below_floor", delta.fetch("acceptable_percentage_points") < floors.fetch("acceptable_improvement_points_below"), delta.fetch("acceptable_percentage_points"), floors.fetch("acceptable_improvement_points_below")),
        floor("too_close_reduction_below_floor", delta.fetch("direct_restatement_too_close_reduction_rate") < floors.fetch("direct_restatement_too_close_reduction_rate_below"), delta.fetch("direct_restatement_too_close_reduction_rate"), floors.fetch("direct_restatement_too_close_reduction_rate_below")),
        floor("acceptable_analogical_retention_below_floor", delta.fetch("acceptable_analogical_transfer_retention_rate") < floors.fetch("acceptable_analogical_transfer_retention_rate_below"), delta.fetch("acceptable_analogical_transfer_retention_rate"), floors.fetch("acceptable_analogical_transfer_retention_rate_below")),
        floor("acceptable_analogical_rate_below_floor", b2.fetch("acceptable_analogical_transfer_rate") < floors.fetch("acceptable_analogical_transfer_rate_below"), b2.fetch("acceptable_analogical_transfer_rate"), floors.fetch("acceptable_analogical_transfer_rate_below")),
        floor("too_far_plus_unrelated_rate_above_floor", ratio(b2.fetch("too_far_plus_unrelated_count"), b2.fetch("outcome_count")) > floors.fetch("too_far_plus_unrelated_rate_above"), ratio(b2.fetch("too_far_plus_unrelated_count"), b2.fetch("outcome_count")), floors.fetch("too_far_plus_unrelated_rate_above"))
      ]
    end

    def low_confidence_sensitivity(integrated, gate)
      acceptable = integrated.dig("quality", "acceptable_count")
      low = integrated.fetch("human_review_required")
      low_acceptable = low.count { |row| row.dig("codex_provisional", "acceptable") }
      low_unacceptable = low.length - low_acceptable
      minimum = acceptable - low_acceptable
      maximum = acceptable + low_unacceptable
      threshold = gate.dig("architecture_candidate_requires_all", "acceptable_outcome", "minimum_count_for_108")
      {
        pair_count: low.length,
        current_acceptable_count: acceptable,
        current_low_acceptable_count: low_acceptable,
        current_low_unacceptable_count: low_unacceptable,
        minimum_acceptable_count: minimum,
        maximum_acceptable_count: maximum,
        minimum_acceptable_rate: ratio(minimum, 108),
        maximum_acceptable_rate: ratio(maximum, 108),
        candidate_minimum_count: threshold,
        can_change_gate_a_outcome: maximum >= threshold
      }
    end

    def condition(id, observed, operator, threshold)
      passed = case operator
               when ">=" then observed >= threshold
               when "<=" then observed <= threshold
               when "==" then observed == threshold
               else raise DataError.new("Unsupported Gate A operator", details: { operator: operator })
               end
      { id: id, observed: observed, operator: operator, threshold: threshold, pass: passed }
    end

    def floor(id, triggered, observed, threshold)
      { id: id, observed: observed, threshold: threshold, triggered: triggered }
    end

    def outcome_reason(outcome, conditions, rejection, sensitivity)
      return "All fixed Gate A candidate conditions passed." if outcome == "architecture_candidate"
      if outcome == "architecture_rejected"
        ids = rejection.select { |floor| floor.fetch(:triggered) }.map { |floor| floor.fetch(:id) }
        return "Fixed rejection floors triggered: #{ids.join(', ')}. Low-confidence best case is #{sensitivity.fetch(:maximum_acceptable_count)}/108 and cannot change the outcome."
      end
      failed = conditions.reject { |condition| condition.fetch(:pass) }.map { |condition| condition.fetch(:id) }
      "No rejection floor triggered, but candidate conditions remain unresolved or failed: #{failed.join(', ')}."
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def criteria_path
      evaluation_path("b_v2_design_criteria_v2.yml")
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def write_json(path, value)
      File.write(path, JSON.pretty_generate(value), mode: "w:UTF-8")
    end
  end
end
