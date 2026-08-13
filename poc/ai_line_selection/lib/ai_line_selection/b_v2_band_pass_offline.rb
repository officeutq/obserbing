# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2BandPassOffline
    VERSION = "b-v2-band-pass-offline-v1"
    MODE = "abstraction_only_v2"
    TOP_NS = [5, 10, 20].freeze
    A_MINS = [0.35, 0.40, 0.45, 0.50, 0.55].freeze
    SURFACE_PROXY_MAXES = [0.12, 0.18, 0.24, 0.30, 0.36].freeze

    def initialize(configuration:, abstraction_results_dir:, surface_results_dir:)
      @configuration = configuration
      @abstraction_results_dir = File.expand_path(abstraction_results_dir)
      @surface_results_dir = File.expand_path(surface_results_dir)
      @data = DataLoader.new(configuration)
    end

    def call(output_path: nil)
      candidate_path = File.join(@abstraction_results_dir, "candidate_sets.jsonl")
      surface_path = File.join(@surface_results_dir, "entry_results.jsonl")
      records = read_jsonl(candidate_path).select { |row| row.fetch("mode") == MODE }
      validate_records!(records)
      labels = final_labels
      entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      lines = @data.lines.select { |line| line.fetch("status") == "approved" }.to_h { |line| [line.fetch("id"), line] }

      grid = TOP_NS.product(A_MINS, SURFACE_PROXY_MAXES).map do |top_n, a_min, s_max|
        evaluate_setting(records, entries, lines, labels, top_n, a_min, s_max)
      end
      actual_surface = actual_surface_sample(surface_path, labels)
      summary = {
        version: VERSION,
        issue: 43,
        completed: true,
        network_call_performed: false,
        external_api_calls: 0,
        embedding_api_calls: 0,
        source: "saved_provider_outputs_plus_offline_surface_proxy",
        entry_count: 36,
        repetition_count: 3,
        outcome_slots: records.length,
        approved_line_count: lines.length,
        top_n_values: TOP_NS,
        abstraction_minimum_values: A_MINS,
        surface_proxy_maximum_values: SURFACE_PROXY_MAXES,
        surface_proxy: {
          version: "unicode-nfkc-character-bigram-cosine-v1",
          role: "diagnostic_only",
          not_interchangeable_with_provider_embedding_cosine: true
        },
        actual_provider_surface_sample: actual_surface,
        grid: grid,
        source_hashes: {
          candidate_sets_sha256: Digest::SHA256.file(candidate_path).hexdigest,
          original_surface_entry_results_sha256: Digest::SHA256.file(surface_path).hexdigest,
          entries_sha256: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
          lines_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
          profile_smoke_outputs_sha256: Digest::SHA256.file(profile_smoke_path).hexdigest
        },
        limitations: [
          "The saved abstraction candidate sets predate the Issue 42 profile and are used only as a 36-entry diagnostic input",
          "Full raw-text provider vectors were not saved; the character-bigram surface score is a sensitivity proxy, not a provider cosine substitute",
          "The saved provider raw-text evidence contains one Top-1 similarity per Entry and cannot reconstruct all candidate surface scores",
          "Reflective-distance labels exist only for previously displayed Entry/Line pairs"
        ]
      }
      File.write(output_path, JSON.pretty_generate(summary), mode: "w:UTF-8") if output_path
      summary.merge(output_path: output_path && File.expand_path(output_path))
    rescue Errno::ENOENT, JSON::ParserError, CSV::MalformedCSVError, Psych::Exception, KeyError => e
      raise DataError.new(
        "B-v2 offline band-pass source is invalid",
        details: { error: e.class.name, message: e.message, source_line: e.backtrace&.first }
      )
    end

    private

    def evaluate_setting(records, entries, lines, labels, top_n, a_min, s_max)
      eligible_counts = []
      labeled = []
      records.each do |record|
        entry = entries.fetch(record.fetch("entry_id"))
        candidates = record.fetch("top_candidates").first(top_n).filter_map do |candidate|
          next if candidate.fetch("similarity").to_f < a_min
          line = lines.fetch(candidate.fetch("line_id"))
          surface = surface_proxy(entry.fetch("body"), line.fetch("text"))
          next if surface > s_max

          label = labels[[entry.fetch("id"), line.fetch("id")]]
          labeled << label.merge(surface_proxy: surface, abstraction_similarity: candidate.fetch("similarity")) if label
          candidate
        end
        eligible_counts << candidates.length
      end
      too_close_total = labeled.count { |row| row.fetch(:relation_type) == "direct_restatement" }
      analogical_acceptable = labeled.count { |row| row.fetch(:relation_type) == "analogical_transfer" && row.fetch(:acceptable) }
      {
        top_n: top_n,
        a_min: a_min,
        surface_proxy_max: s_max,
        eligible_count: {
          average: average(eligible_counts),
          p50: percentile(eligible_counts, 0.50),
          p95: percentile(eligible_counts, 0.95),
          minimum: eligible_counts.min,
          maximum: eligible_counts.max,
          zero_slots: eligible_counts.count(&:zero?),
          zero_rate: ratio(eligible_counts.count(&:zero?), eligible_counts.length)
        },
        labeled_candidate_occurrences: labeled.length,
        labeled_acceptable_rate: ratio(labeled.count { |row| row.fetch(:acceptable) }, labeled.length),
        labeled_distance_counts: labeled.map { |row| row.fetch(:distance) }.tally.sort.to_h,
        labeled_relation_counts: labeled.map { |row| row.fetch(:relation_type) }.tally.sort.to_h,
        direct_restatement_occurrences: too_close_total,
        too_far_plus_unrelated_occurrences: labeled.count { |row| %w[weak_connection unrelated].include?(row.fetch(:relation_type)) },
        acceptable_analogical_occurrences: analogical_acceptable
      }
    end

    def actual_surface_sample(path, labels)
      rows = read_jsonl(path).select do |row|
        row.fetch("provider") == "openai-small" && row.fetch("variant") == "original"
      end
      values = rows.map { |row| row.dig("top_candidate", "similarity").to_f }
      labeled = rows.filter_map do |row|
        line_id = row.dig("top_candidate", "line_id")
        label = labels[[row.fetch("entry_id"), line_id]]
        label && label.merge(similarity: row.dig("top_candidate", "similarity"))
      end
      threshold_diagnostics = [0.55, 0.58, 0.60, 0.62, 0.65].to_h do |threshold|
        excluded = labeled.select { |row| row.fetch(:similarity).to_f > threshold }
        [threshold.to_s, {
          all_top_1_excluded_count: values.count { |value| value > threshold },
          labeled_excluded_count: excluded.length,
          labeled_excluded_distance_counts: excluded.map { |row| row.fetch(:distance) }.tally.sort.to_h
        }]
      end
      {
        provider: "openai",
        model: "text-embedding-3-small",
        variant: "original",
        dimensions: 1536,
        entry_count: rows.length,
        evidence_scope: "saved_top_1_per_entry_only",
        similarity: {
          minimum: values.min,
          p50: percentile(values, 0.50),
          p95: percentile(values, 0.95),
          maximum: values.max
        },
        count_above_0_60: values.count { |value| value > 0.60 },
        labeled_top_1_count: labeled.length,
        labeled_top_1_distance_counts: labeled.map { |row| row.fetch(:distance) }.tally.sort.to_h,
        threshold_diagnostics: threshold_diagnostics
      }
    end

    def final_labels
      codex_path = evaluation_path("reflective_distance_codex_judgments_v1.csv")
      labels = CSV.read(codex_path, headers: true, encoding: "UTF-8").to_h do |row|
        entry_id, line_id = row.fetch("pair_id").split("/")
        [[entry_id, line_id], {
          acceptable: row.fetch("acceptable") == "true",
          distance: row.fetch("distance"),
          relation_type: row.fetch("relation_type")
        }]
      end
      human = YAML.safe_load_file(
        evaluation_path("reflective_distance_human_review_v1.yml"),
        permitted_classes: [], aliases: false
      )
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
      normalized = text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:][:punct:]]+/, "")
      chars = normalized.chars
      return chars if chars.length < 2
      chars.each_cons(2).map(&:join)
    end

    def validate_records!(records)
      unless records.length == 108 && records.map { |row| row.fetch("entry_id") }.uniq.length == 36
        raise DataError.new("B-v2 band-pass requires 36 Entries x 3 repetitions")
      end
    end

    def read_jsonl(path)
      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def profile_smoke_path
      evaluation_path("b_v2_profile_smoke_outputs_v1.jsonl")
    end

    def percentile(values, fraction)
      return nil if values.empty?
      ordered = values.sort
      ordered.fetch([(ordered.length * fraction).ceil - 1, 0].max).round(4)
    end

    def average(values)
      return 0.0 if values.empty?
      (values.sum.to_f / values.length).round(4)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?
      (numerator.to_f / denominator).round(4)
    end
  end
end
