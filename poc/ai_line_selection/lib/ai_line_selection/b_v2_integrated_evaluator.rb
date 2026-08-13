# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2IntegratedEvaluator
    VERSION = "b-v2-integrated-evaluation-v1"

    def initialize(configuration:, results_dir:, judgments_path:)
      @configuration = configuration
      @results_dir = File.expand_path(results_dir)
      @judgments_path = File.expand_path(judgments_path)
      @entries = DataLoader.new(configuration).entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = DataLoader.new(configuration).lines.to_h { |line| [line.fetch("id"), line] }
    end

    def call(output_path: nil, outcomes_path: nil)
      provider_outputs = read_jsonl(File.join(@results_dir, "provider_outputs.jsonl"))
      live_summary = JSON.parse(File.read(File.join(@results_dir, "summary.json"), encoding: "UTF-8"))
      labels = final_labels.merge(new_labels)
      outcomes = provider_outputs.map { |row| evaluate_outcome(row, labels) }
      validate_complete!(outcomes)
      summary = build_summary(outcomes, live_summary)
      write_json(output_path, summary) if output_path
      write_jsonl(outcomes_path, outcomes) if outcomes_path
      summary
    end

    private

    def new_labels
      CSV.read(@judgments_path, headers: true, encoding: "UTF-8").to_h do |row|
        label = normalize_label(row.to_h.merge("judge" => "codex_integrated_v1"))
        [row.fetch("pair_id"), label]
      end
    end

    def final_labels
      codex_path = evaluation_path("reflective_distance_codex_judgments_v1.csv")
      labels = CSV.read(codex_path, headers: true, encoding: "UTF-8").to_h do |row|
        [row.fetch("pair_id"), normalize_label(row.to_h.merge("judge" => "codex_reassessment"))]
      end
      human_path = evaluation_path("reflective_distance_human_review_v1.yml")
      human = YAML.safe_load_file(human_path, permitted_classes: [], aliases: false)
      human.fetch("reviews").each do |review|
        label = review.fetch("final_labels").merge(
          "pair_id" => review.fetch("pair_id"),
          "confidence" => "human_confirmed",
          "reason" => "Product-owner decision normalized to reflective-distance-v1.",
          "judge" => "human_review",
          "reviewer_role" => "product_owner"
        )
        labels[review.fetch("pair_id")] = normalize_label(label)
      end
      labels
    end

    def normalize_label(label)
      normalized = label.transform_keys(&:to_s)
      %w[acceptable user_fact_assertion explicit_contradiction advice_or_diagnosis clearly_unrelated].each do |key|
        normalized[key] = case normalized.fetch(key)
                          when true, "true" then true
                          when false, "false" then false
                          else raise DataError.new("Invalid boolean judgment", details: { pair_id: normalized["pair_id"], field: key })
                          end
      end
      acceptable = normalized.fetch("acceptable")
      valid = acceptable ?
        normalized.fetch("distance") == "just_right" && %w[same_domain analogical_transfer].include?(normalized.fetch("relation_type")) :
        %w[too_close too_far not_obserbing].include?(normalized.fetch("distance")) && %w[direct_restatement weak_connection unrelated].include?(normalized.fetch("relation_type"))
      raise DataError.new("Judgment violates reflective-distance-v1", details: { pair_id: normalized["pair_id"] }) unless valid
      normalized
    end

    def evaluate_outcome(row, labels)
      if row.fetch("semantic_silence")
        return {
          "entry_id" => row.fetch("entry_id"), "repetition" => row.fetch("repetition"),
          "selected_line_id" => nil, "acceptable" => false,
          "distance" => "semantic_silence", "relation_type" => "semantic_silence",
          "judge" => "selector_outcome", "confidence" => "not_applicable",
          "user_fact_assertion" => false, "explicit_contradiction" => false,
          "advice_or_diagnosis" => false, "clearly_unrelated" => false
        }
      end

      pair_id = "#{row.fetch('entry_id')}/#{row.fetch('selected_line_id')}"
      label = labels[pair_id]
      raise DataError.new("Missing reflective-distance judgment", details: { pair_id: pair_id }) unless label
      label.slice(
        "acceptable", "distance", "relation_type", "user_fact_assertion", "explicit_contradiction",
        "advice_or_diagnosis", "clearly_unrelated", "confidence", "reason", "judge", "reviewer_role"
      ).merge(
        "entry_id" => row.fetch("entry_id"), "repetition" => row.fetch("repetition"),
        "selected_line_id" => row.fetch("selected_line_id"), "pair_id" => pair_id
      )
    end

    def validate_complete!(outcomes)
      expected = @entries.length * Bv2IntegratedComparison::REPETITIONS
      raise DataError.new("Integrated evaluation outcome count mismatch", details: { expected: expected, actual: outcomes.length }) unless outcomes.length == expected
      slots = outcomes.map { |row| [row.fetch("entry_id"), row.fetch("repetition")] }
      raise DataError.new("Integrated evaluation contains duplicate slots") unless slots.uniq.length == slots.length
    end

    def build_summary(outcomes, live_summary)
      displayed = outcomes.reject { |row| row.fetch("distance") == "semantic_silence" }
      acceptable = outcomes.count { |row| row.fetch("acceptable") }
      low = displayed.select { |row| row.fetch("confidence") == "low" }
      low_by_pair = low.group_by { |row| row.fetch("pair_id") }
      all_three = outcomes.group_by { |row| row.fetch("entry_id") }.count do |_entry_id, rows|
        rows.length == 3 && rows.all? { |row| row.fetch("acceptable") }
      end
      {
        version: VERSION,
        issue: 46,
        source: "fixed_synthetic",
        rubric: "reflective-distance-v1",
        execution: live_summary.fetch("execution"),
        quality: {
          denominator: outcomes.length,
          displayed_line_count: displayed.length,
          semantic_silence_count: outcomes.length - displayed.length,
          acceptable_count: acceptable,
          acceptable_rate: ratio(acceptable, outcomes.length),
          distance_counts: outcomes.map { |row| row.fetch("distance") }.tally.sort.to_h,
          relation_type_counts: outcomes.map { |row| row.fetch("relation_type") }.tally.sort.to_h,
          acceptable_analogical_transfer_count: outcomes.count { |row| row.fetch("acceptable") && row.fetch("relation_type") == "analogical_transfer" },
          analogical_transfer_count: outcomes.count { |row| row.fetch("relation_type") == "analogical_transfer" },
          direct_restatement_too_close_count: outcomes.count { |row| row.fetch("relation_type") == "direct_restatement" },
          too_far_plus_unrelated_count: outcomes.count { |row| %w[weak_connection unrelated].include?(row.fetch("relation_type")) },
          unrelated_count: outcomes.count { |row| row.fetch("relation_type") == "unrelated" },
          all_three_repetitions_acceptable_entry_count: all_three,
          all_three_repetitions_acceptable_entry_rate: ratio(all_three, @entries.length),
          user_fact_assertion_count: outcomes.count { |row| row.fetch("user_fact_assertion") },
          explicit_contradiction_count: outcomes.count { |row| row.fetch("explicit_contradiction") },
          advice_or_diagnosis_count: outcomes.count { |row| row.fetch("advice_or_diagnosis") },
          clearly_unrelated_count: outcomes.count { |row| row.fetch("clearly_unrelated") },
          unresolved_low_confidence_occurrence_count: low.length,
          unresolved_low_confidence_pair_count: low.map { |row| row.fetch("pair_id") }.uniq.length
        },
        human_review_required: low_by_pair.map { |_pair_id, rows| human_review_item(rows.first, rows.length) },
        safety: live_summary.fetch("safety"),
        selection: live_summary.fetch("selection"),
        latency_ms: live_summary.fetch("latency_ms"),
        api_and_cost: live_summary.fetch("api_and_cost"),
        technical_error_count: live_summary.fetch("technical_error_count"),
        source_hashes: {
          provider_outputs_sha256: Digest::SHA256.file(File.join(@results_dir, "provider_outputs.jsonl")).hexdigest,
          live_summary_sha256: Digest::SHA256.file(File.join(@results_dir, "summary.json")).hexdigest,
          judgments_sha256: Digest::SHA256.file(@judgments_path).hexdigest
        },
        external_api_calls_for_reflective_distance_evaluation: 0
      }
    end

    def human_review_item(row, occurrence_count)
      entry_id = row.fetch("entry_id")
      line_id = row.fetch("selected_line_id")
      {
        pair_id: row.fetch("pair_id"),
        occurrence_count: occurrence_count,
        entry_text: @entries.fetch(entry_id).fetch("body"),
        line_text: @lines.fetch(line_id).fetch("text"),
        codex_provisional: row.slice("acceptable", "distance", "relation_type", "reason", "confidence")
      }
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def read_jsonl(path)
      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def write_json(path, value)
      File.write(path, JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def write_jsonl(path, values)
      File.write(path, values.map { |value| JSON.generate(value) }.join("\n") + "\n", mode: "w:UTF-8")
    end
  end
end
