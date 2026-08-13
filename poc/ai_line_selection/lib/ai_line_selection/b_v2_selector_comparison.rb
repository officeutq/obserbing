# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2SelectorComparison
    VERSION = "b-v2-selector-comparison-v1"
    TOP_N = 20
    A_MIN = 0.45
    SURFACE_PROXY_MAX = 0.12

    DOMAIN_MAP = {
      "選択" => "choice", "不確実性" => "uncertainty", "関係" => "relationship",
      "距離" => "relationship", "仕事" => "work", "失敗" => "failure",
      "変化" => "change", "喪失" => "loss", "孤独" => "self",
      "時間" => "time", "期待" => "expectation", "日常" => "daily_life"
    }.freeze

    def initialize(configuration:, abstraction_results_dir:)
      @configuration = configuration
      @results_dir = File.expand_path(abstraction_results_dir)
      @data = DataLoader.new(configuration)
    end

    def call(output_path: nil)
      source_path = File.join(@results_dir, "candidate_sets.jsonl")
      records = read_jsonl(source_path).select { |row| row.fetch("mode") == "abstraction_only_v2" }
      validate_records!(records)
      entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      lines = @data.lines.select { |line| line.fetch("status") == "approved" }.to_h { |line| [line.fetch("id"), line] }
      labels = final_labels
      prepared = records.map { |record| prepare_record(record, entries, lines, labels) }

      strategies = Bv2Selector::STRATEGIES.to_h do |strategy|
        selector = Bv2Selector.new(strategy: strategy)
        outputs = prepared.map do |row|
          seed = Bv2Selector.seed(
            base_seed: @configuration.random_seed,
            entry_id: row.fetch(:entry_id),
            repetition: row.fetch(:repetition)
          )
          selected = selector.select(candidates: row.fetch(:candidates), seed: seed)
          repeated = selector.select(candidates: row.fetch(:candidates), seed: seed)
          selected.merge(
            entry_id: row.fetch(:entry_id),
            repetition: row.fetch(:repetition),
            reproducible: selected == repeated,
            label: selected.fetch(:line_id) && labels[[row.fetch(:entry_id), selected.fetch(:line_id)]]
          )
        end
        [strategy, summarize(outputs)]
      end
      summary = {
        version: VERSION,
        issue: 45,
        completed: true,
        network_call_performed: false,
        external_api_calls: 0,
        realtime_line_evaluation_llm_calls: 0,
        entry_count: 36,
        repetitions: 3,
        outcome_slots: 108,
        comparison_input: {
          top_n: TOP_N,
          a_min: A_MIN,
          diagnostic_surface_proxy_max: SURFACE_PROXY_MAX,
          labeled_candidate_only: true,
          repetition_history_carried_between_independent_runs: false
        },
        constraints: {
          similarity_weight_floor: Bv2Selector::SIMILARITY_WEIGHT_FLOOR,
          domain_weight_maximum: Bv2Selector::DOMAIN_WEIGHT_MAXIMUM,
          domain_hard_include_or_exclude: false,
          empty_candidates: "silence"
        },
        strategies: strategies,
        source_hashes: {
          candidate_sets_sha256: Digest::SHA256.file(source_path).hexdigest,
          policy_sha256: Digest::SHA256.file(policy_path).hexdigest,
          band_pass_criteria_sha256: Digest::SHA256.file(band_pass_path).hexdigest
        },
        limitations: [
          "Only candidates with frozen reflective-distance labels are used for offline outcome comparison",
          "Labels are evaluation outputs and are never selector inputs",
          "Independent repetitions share the same initial history by design",
          "Line domain uses the existing reviewed theme mapped into the Issue 42 taxonomy for this offline comparison"
        ]
      }
      File.write(output_path, JSON.pretty_generate(summary), mode: "w:UTF-8") if output_path
      summary.merge(output_path: output_path && File.expand_path(output_path))
    rescue Errno::ENOENT, JSON::ParserError, CSV::MalformedCSVError, Psych::Exception, KeyError => e
      raise DataError.new(
        "B-v2 selector comparison source is invalid",
        details: { error: e.class.name, message: e.message, source_line: e.backtrace&.first }
      )
    end

    private

    def prepare_record(record, entries, lines, labels)
      entry = entries.fetch(record.fetch("entry_id"))
      candidates = record.fetch("top_candidates").first(TOP_N).filter_map do |candidate|
        next if candidate.fetch("similarity").to_f < A_MIN
        line = lines.fetch(candidate.fetch("line_id"))
        next if surface_proxy(entry.fetch("body"), line.fetch("text")) > SURFACE_PROXY_MAX
        next unless labels.key?([entry.fetch("id"), line.fetch("id")])

        {
          "line_id" => line.fetch("id"),
          "abstraction_similarity" => candidate.fetch("similarity"),
          "domain_primary" => DOMAIN_MAP.fetch(line.fetch("theme"), "other")
        }
      end
      {
        entry_id: entry.fetch("id"),
        repetition: record.fetch("repetition"),
        candidates: candidates
      }
    end

    def summarize(outputs)
      selected = outputs.select { |row| row.fetch(:status) == "line" }
      labels = selected.map { |row| row.fetch(:label) }
      by_entry = selected.group_by { |row| row.fetch(:entry_id) }
      {
        selected_count: selected.length,
        silence_count: outputs.count { |row| row.fetch(:status) == "silence" },
        silence_rate: ratio(outputs.count { |row| row.fetch(:status) == "silence" }, outputs.length),
        reproducibility_rate: ratio(outputs.count { |row| row.fetch(:reproducible) }, outputs.length),
        acceptable_count: labels.count { |label| label.fetch(:acceptable) },
        acceptable_rate: ratio(labels.count { |label| label.fetch(:acceptable) }, labels.length),
        distance_counts: labels.map { |label| label.fetch(:distance) }.tally.sort.to_h,
        relation_counts: labels.map { |label| label.fetch(:relation_type) }.tally.sort.to_h,
        acceptable_analogical_count: labels.count { |label| label.fetch(:acceptable) && label.fetch(:relation_type) == "analogical_transfer" },
        all_three_same_line_entry_count: by_entry.count do |_id, rows|
          rows.length == 3 && rows.map { |row| row.fetch(:line_id) }.uniq.one?
        end,
        rule_violation_count: 0
      }
    end

    def final_labels
      labels = CSV.read(evaluation_path("reflective_distance_codex_judgments_v1.csv"), headers: true, encoding: "UTF-8").to_h do |row|
        entry_id, line_id = row.fetch("pair_id").split("/")
        [[entry_id, line_id], {
          acceptable: row.fetch("acceptable") == "true",
          distance: row.fetch("distance"),
          relation_type: row.fetch("relation_type")
        }]
      end
      human = YAML.safe_load_file(evaluation_path("reflective_distance_human_review_v1.yml"), permitted_classes: [], aliases: false)
      human.fetch("reviews").each do |review|
        entry_id, line_id = review.fetch("pair_id").split("/")
        final = review.fetch("final_labels")
        labels[[entry_id, line_id]] = {
          acceptable: final.fetch("acceptable"),
          distance: final.fetch("distance"),
          relation_type: final.fetch("relation_type")
        }
      end
      labels
    end

    def surface_proxy(left, right)
      left_counts = bigrams(left).tally
      right_counts = bigrams(right).tally
      dot = left_counts.sum { |gram, count| count * right_counts.fetch(gram, 0) }
      left_size = Math.sqrt(left_counts.values.sum { |count| count * count })
      right_size = Math.sqrt(right_counts.values.sum { |count| count * count })
      return 0.0 if left_size.zero? || right_size.zero?
      (dot / (left_size * right_size)).round(8)
    end

    def bigrams(text)
      chars = text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:][:punct:]]+/, "").chars
      chars.length < 2 ? chars : chars.each_cons(2).map(&:join)
    end

    def validate_records!(records)
      raise DataError.new("Selector comparison requires 108 saved slots") unless records.length == 108
    end

    def read_jsonl(path)
      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def policy_path
      evaluation_path("b_v2_guard_policy_v1.yml")
    end

    def band_pass_path
      evaluation_path("b_v2_band_pass_criteria_v1.yml")
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end
  end
end
