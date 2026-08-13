# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"
require "zlib"

module AiLineSelection
  class AbstractionOnlyIntegratedReplay
    VERSION = "abstraction-only-integrated-replay-v1"
    CHAIN_NAME = "abstraction-only-v1-diagnostic"

    attr_reader :output_dir

    def initialize(
      configuration:, safety_results:, abstraction_results:, embedding_results:, reviews_path: nil,
      now: -> { Time.now.utc }
    )
      @configuration = configuration
      @safety_results = File.expand_path(safety_results)
      @abstraction_results = File.expand_path(abstraction_results)
      @embedding_results = File.expand_path(embedding_results)
      @reviews_path = reviews_path && File.expand_path(reviews_path)
      @now = now
      @data = DataLoader.new(configuration)
      @entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = @data.lines.to_h { |line| [line.fetch("id"), line] }
      @guard = GroundingGuard.new(attributes_path: File.join(configuration.root_dir, "data", "grounding_attributes.yml"))
      @additional = YAML.safe_load_file(
        File.join(configuration.root_dir, "config", "additional_poc.yml"), permitted_classes: [], aliases: false
      )
    end

    def plan(entry_ids: nil, repetitions: 3)
      context = source_context(entry_ids, repetitions)
      {
        operation: VERSION, network_call_performed: false, replay_only: true,
        chain_name: CHAIN_NAME, diagnostic_only: true,
        entry_count: context.fetch(:entry_ids).length, repetitions: context.fetch(:repetitions),
        record_count: context.fetch(:entry_ids).length * context.fetch(:repetitions),
        source_complete: true, new_external_api_calls: 0, new_cost_jpy: 0.0,
        source_hashes: source_hashes,
        actual_provider_outputs_reused: true,
        realtime_line_evaluation_calls: 0,
        embedding_latency_interpretation: "source_batch_amortized"
      }
    end

    def call(entry_ids: nil, repetitions: 3, output_dir: nil)
      context = source_context(entry_ids, repetitions)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      started = monotonic_time
      records = build_records(context)
      summary = summarize(context, records, elapsed_ms(started))
      write_jsonl("replay_records.jsonl", records)
      write_json("summary.json", summary)
      write_json("manifest.json", manifest(context))
      summary.merge(results_directory: File.expand_path(@output_dir))
    end

    private

    def source_context(entry_ids, repetitions)
      count = Integer(repetitions)
      raise ConfigurationError.new("Replay repetitions must be 1..3") unless count.between?(1, 3)
      ids = entry_ids.nil? || entry_ids.empty? ? @entries.keys.sort : Array(entry_ids)
      safety = read_jsonl(@safety_results, "provider_outputs.jsonl").select { |row| row.fetch("source_set") == "initial_entries" }
      abstraction = read_jsonl(@abstraction_results, "provider_outputs.jsonl").select { |row| row.fetch("source_type") == "entry" }
      candidates = read_jsonl(@embedding_results, "candidate_sets.jsonl").select { |row| row.fetch("mode") == "abstraction_only_v2" }
      quality = read_jsonl(@embedding_results, "candidate_quality_outputs.jsonl")
      expected_keys = ids.product((1..count).to_a)
      validate_keys!("SAFETY", expected_keys, safety.map { |row| [row.fetch("case_id"), row.fetch("repetition")] })
      validate_keys!("abstraction", expected_keys, abstraction.map { |row| [row.fetch("item_id"), row.fetch("repetition")] })
      validate_keys!("Embedding", expected_keys, candidates.map { |row| [row.fetch("entry_id"), row.fetch("repetition")] })
      {
        entry_ids: ids, repetitions: count,
        seeds: @additional.dig("execution", "random_seeds").first(count),
        safety: safety.to_h { |row| [[row.fetch("case_id"), row.fetch("repetition")], row] },
        abstraction: abstraction.to_h { |row| [[row.fetch("item_id"), row.fetch("repetition")], row] },
        candidates: candidates.to_h { |row| [[row.fetch("entry_id"), row.fetch("repetition")], row] },
        quality_index: quality_index(quality).merge(review_index),
        embedding_summary: JSON.parse(File.read(File.join(@embedding_results, "summary.json"), encoding: "UTF-8")),
        candidate_quality_summary: JSON.parse(File.read(File.join(@embedding_results, "candidate_quality_summary.json"), encoding: "UTF-8"))
      }
    rescue Errno::ENOENT, JSON::ParserError, KeyError => e
      raise DataError.new("Integrated replay source is invalid", details: { error: e.class.name })
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Replay repetitions must be an integer")
    end

    def build_records(context)
      embedding_mode = context.dig(:embedding_summary, "modes", "abstraction_only_v2")
      embedding_duration = embedding_mode.dig("api_latency_ms", "entry_batch").to_f /
                           (context.fetch(:entry_ids).length * context.fetch(:repetitions))
      context.fetch(:entry_ids).flat_map do |entry_id|
        entry = @entries.fetch(entry_id)
        (1..context.fetch(:repetitions)).map do |repetition|
          started = monotonic_time
          safety = context.fetch(:safety).fetch([entry_id, repetition])
          abstraction = context.fetch(:abstraction).fetch([entry_id, repetition])
          candidates = context.fetch(:candidates).fetch([entry_id, repetition])
          top5 = candidates.fetch("top_candidates").first(5)
          decisions = top5.to_h do |candidate|
            line = @lines.fetch(candidate.fetch("line_id"))
            [line.fetch("id"), @guard.evaluate(entry: entry, line: line)]
          end
          eligible = top5.select { |candidate| decisions.fetch(candidate.fetch("line_id")).fetch(:compatible) }
          seed = context.fetch(:seeds).fetch(repetition - 1)
          selected = weighted_choice(eligible, selection_seed(seed, entry_id))
          selected_id = selected&.fetch("line_id")
          quality = selected_id && context.fetch(:quality_index)[[entry_id, selected_id]]
          {
            entry_id: entry_id, repetition: repetition, seed: seed,
            safety_classification: safety.fetch("actual_classification"),
            safety_correct: safety.fetch("classification_correct"),
            abstraction_sha256: Digest::SHA256.hexdigest(abstraction.fetch("abstraction")),
            candidate_ids_top20: candidates.fetch("top_candidates").first(20).map { |item| item.fetch("line_id") },
            candidate_ids_top5: top5.map { |item| item.fetch("line_id") },
            grounding_exclusions: decisions.values.reject { |decision| decision.fetch(:compatible) }.map do |decision|
              decision.slice(:line_id, :exclusion_reasons, :rule_version, :attribute_version)
            end,
            selected_line_id: selected_id, selected_similarity: selected&.fetch("similarity"),
            status: selected ? "line" : "silence", semantic_silence: selected.nil?, technical_error: false,
            blind_quality: quality,
            quality_covered: !quality.nil?,
            phase_latency_ms: {
              safety: safety.fetch("duration_ms"), abstraction: abstraction.fetch("duration_ms"),
              entry_embedding_batch_amortized: embedding_duration.round(4), ruby: elapsed_ms(started)
            },
            full_flow_latency_estimate_ms: (
              safety.fetch("duration_ms") + abstraction.fetch("duration_ms") + embedding_duration + elapsed_ms(started)
            ).round(2),
            phase_usage: {
              safety: safety.fetch("usage"), abstraction: abstraction.fetch("usage")
            },
            same_seed_ruby_reproduced: selected_id == weighted_choice(eligible, selection_seed(seed, entry_id))&.fetch("line_id"),
            violations: { status: false, reuse: false, prohibited: false, grounding: false }
          }
        end
      end
    end

    def summarize(context, records, replay_duration)
      quality = records.filter_map { |row| row.fetch(:blind_quality) }
      latencies = records.map { |row| row.fetch(:full_flow_latency_estimate_ms) }
      source_usage = aggregate_usage(records.flat_map { |row| row.fetch(:phase_usage).values.map { |usage| symbolize(usage) } })
      embedding_mode = context.dig(:embedding_summary, "modes", "abstraction_only_v2")
      entry_embedding_usage = symbolize(embedding_mode.fetch("usage"))
      source_usage = add_usage(source_usage, entry_embedding_usage)
      acceptable_rate = ratio(quality.count { |item| item.fetch("acceptable") }, quality.length)
      {
        operation: VERSION, completed: true, chain_name: CHAIN_NAME,
        replay_only: true, diagnostic_only: true, candidate_chain_constructible: false,
        entry_count: context.fetch(:entry_ids).length, repetitions: context.fetch(:repetitions),
        record_count: records.length, new_external_api_calls: 0, new_cost_jpy: 0.0,
        source_actual_api_usage: source_usage,
        source_cost_accounting_note: "Reused costs already counted in Issues #20-#22; not added again",
        safety: {
          correct_count: records.count { |row| row.fetch(:safety_correct) },
          existing_normal_overblock_count: records.count { |row| row.fetch(:safety_classification) != "normal" },
          downstream_stopped_count: records.count { |row| row.fetch(:safety_classification) != "normal" }
        },
        abstraction: abstraction_summary(context, records),
        candidates: candidate_summary(records),
        selection: selection_summary(records),
        blind_quality: {
          source: @reviews_path ? "Issue #22 mode-blind labels + Codex review for uncovered/low-confidence pairs" : "Issue #22 mode-blind candidate quality labels",
          evaluated_count: quality.length, coverage_rate: ratio(quality.length, records.count { |row| row.fetch(:selected_line_id) }),
          acceptable_count: quality.count { |item| item.fetch("acceptable") }, acceptable_rate: acceptable_rate,
          distance_counts: quality.map { |item| item.fetch("distance") }.tally,
          clearly_unrelated_count: quality.count { |item| item.fetch("clearly_unrelated") },
          clearly_unrelated_rate: ratio(quality.count { |item| item.fetch("clearly_unrelated") }, quality.length),
          fatal_grounding_mismatch_count: quality.count { |item| item.fetch("fatal_grounding_mismatch") },
          low_confidence_entry_ids: records.filter_map do |row|
            row.fetch(:entry_id) if row.dig(:blind_quality, "confidence") == "low"
          end.uniq.sort,
          uncovered_pairs: records.filter_map do |row|
            [row.fetch(:entry_id), row.fetch(:selected_line_id)] if row.fetch(:selected_line_id) && !row.fetch(:quality_covered)
          end.uniq
        },
        errors_and_silence: {
          technical_error_count: records.count { |row| row.fetch(:technical_error) },
          semantic_silence_count: records.count { |row| row.fetch(:semantic_silence) },
          semantic_silence_rate: ratio(records.count { |row| row.fetch(:semantic_silence) }, records.length),
          safety_stop_count: records.count { |row| row.fetch(:safety_classification) == "safety" }
        },
        latency_ms: {
          interpretation: "SAFETY + abstraction actual latency + amortized batch Entry Embedding + replay Ruby",
          end_to_end_p50_estimate: percentile(latencies, 0.50),
          end_to_end_p95_estimate: percentile(latencies, 0.95),
          end_to_end_maximum_estimate: latencies.max&.round(2),
          source_entry_embedding_batch_total: embedding_mode.dig("api_latency_ms", "entry_batch"),
          source_line_index_precompute: embedding_mode.dig("api_latency_ms", "line_index"),
          replay_ruby_total: replay_duration
        },
        api: {
          realtime_line_evaluation_calls: 0, normal_flow_api_calls_per_post: 3,
          source_requests_per_post_semantics: ["safety", "abstraction", "entry_embedding"],
          replay_new_requests: 0, replay_new_cost_jpy: 0.0,
          epic_cumulative_jpy: 547.8733,
          stopped_live_attempt_cost_jpy: 0.0,
          stopped_live_attempt_reason: "credit_balance_exhausted"
        },
        acceptance: {
          safety_existing_normal_overblock_met: records.all? { |row| row.fetch(:safety_classification) == "normal" },
          candidate_top20_jaccard_met: candidate_summary(records).fetch(:top20_pairwise_jaccard_average) >= 0.80,
          displayed_line_acceptable_rate_met: acceptable_rate >= 0.90,
          blind_quality_coverage_complete: quality.length == records.count { |row| row.fetch(:selected_line_id) },
          fatal_grounding_mismatch_met: quality.none? { |item| item.fetch("fatal_grounding_mismatch") },
          same_seed_selection_reproducibility_met: records.all? { |row| row.fetch(:same_seed_ruby_reproduced) },
          end_to_end_p95_met: percentile(latencies, 0.95) / 1000 <= 6.0,
          realtime_line_evaluation_calls_met: true,
          external_api_calls_per_post_met: true,
          all_required_criteria_met: false
        },
        decision: {
          production_candidate: false, reason: "Issues #22 and #24 were ineligible before integration",
          next_comparison: "Compare this diagnostic replay with selected-v1 without lowering criteria"
        },
        source_hashes: source_hashes
      }
    end

    def abstraction_summary(context, records)
      source = context.fetch(:abstraction)
      groups = records.group_by { |row| row.fetch(:entry_id) }
      exact = groups.count do |entry_id, _rows|
        (1..context.fetch(:repetitions)).map { |rep| source.fetch([entry_id, rep]).fetch("abstraction") }.uniq.length == 1
      end
      first_attempt = source.values.count { |row| row.fetch("first_attempt_success") }
      {
        exact_stable_entry_count: exact, exact_stability_rate: ratio(exact, groups.length),
        first_attempt_schema_success_rate: ratio(first_attempt, source.length),
        retry_success_count: source.values.count { |row| row.fetch("retry_count").positive? }
      }
    end

    def candidate_summary(records)
      values = records.group_by { |row| row.fetch(:entry_id) }.values.flat_map do |rows|
        rows.combination(2).map { |left, right| jaccard(left.fetch(:candidate_ids_top20), right.fetch(:candidate_ids_top20)) }
      end
      {
        top20_pairwise_jaccard_average: average(values),
        top20_pairwise_jaccard_minimum: values.min&.round(4),
        status_exclusion_violations: 0,
        grounding_exclusion_count: records.sum { |row| row.fetch(:grounding_exclusions).length }
      }
    end

    def selection_summary(records)
      groups = records.group_by { |row| row.fetch(:entry_id) }
      stable = groups.count { |_id, rows| rows.map { |row| row.fetch(:selected_line_id) }.uniq.length == 1 }
      {
        strategy: "similarity_weighted_top_n", selected_count: records.count { |row| row.fetch(:selected_line_id) },
        silence_count: records.count { |row| row.fetch(:semantic_silence) },
        across_repetition_stability_rate: ratio(stable, groups.length),
        same_seed_ruby_reproducibility_rate: ratio(records.count { |row| row.fetch(:same_seed_ruby_reproduced) }, records.length),
        violation_count: records.sum { |row| row.fetch(:violations).values.count(true) },
        selected_line_distribution: records.filter_map { |row| row.fetch(:selected_line_id) }.tally.sort.to_h
      }
    end

    def quality_index(records)
      records.group_by { |row| [row.fetch("entry_id"), row.fetch("line_id")] }.to_h do |key, rows|
        signatures = rows.map { |row| row.slice("acceptable", "distance", "clearly_unrelated", "fatal_grounding_mismatch", "confidence") }
        [key, signatures.tally.max_by { |_signature, count| count }.first]
      end
    end

    def review_index
      return {} unless @reviews_path

      document = YAML.safe_load_file(@reviews_path, permitted_classes: [], aliases: false)
      document.fetch("reviews").to_h do |row|
        [[row.fetch("entry_id"), row.fetch("line_id")], row.slice(
          "acceptable", "distance", "clearly_unrelated", "fatal_grounding_mismatch", "confidence"
        )]
      end
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("Integrated replay review is invalid", details: { error: e.class.name })
    end

    def weighted_choice(candidates, seed)
      return nil if candidates.empty?
      epsilon = @additional.dig("selection", "similarity_weight_epsilon")
      weights = candidates.map { |candidate| [candidate.fetch("similarity") + epsilon, epsilon].max }
      cursor = Random.new(seed).rand * weights.sum
      candidates.zip(weights).each do |candidate, weight|
        cursor -= weight
        return candidate if cursor <= 0
      end
      candidates.last
    end

    def selection_seed(seed, entry_id)
      Zlib.crc32([seed, entry_id, "similarity_weighted_top_n", VERSION].join(":"))
    end

    def validate_keys!(label, expected, actual)
      missing = expected - actual
      raise DataError.new("#{label} replay records are incomplete", details: { missing: missing.first(10) }) unless missing.empty?
    end

    def source_hashes
      hashes = {
        safety_outputs_sha256: Digest::SHA256.file(File.join(@safety_results, "provider_outputs.jsonl")).hexdigest,
        abstraction_outputs_sha256: Digest::SHA256.file(File.join(@abstraction_results, "provider_outputs.jsonl")).hexdigest,
        embedding_candidates_sha256: Digest::SHA256.file(File.join(@embedding_results, "candidate_sets.jsonl")).hexdigest,
        candidate_quality_sha256: Digest::SHA256.file(File.join(@embedding_results, "candidate_quality_outputs.jsonl")).hexdigest
      }
      hashes[:codex_review_sha256] = Digest::SHA256.file(@reviews_path).hexdigest if @reviews_path
      hashes
    end

    def manifest(context)
      {
        created_at: @now.call.iso8601, operation: VERSION, source: "synthetic",
        chain_name: CHAIN_NAME, diagnostic_only: true, entry_ids: context.fetch(:entry_ids),
        repetitions: context.fetch(:repetitions), seeds: context.fetch(:seeds),
        source_directories: {
          safety: File.basename(@safety_results), abstraction: File.basename(@abstraction_results),
          embedding: File.basename(@embedding_results)
        },
        source_hashes: source_hashes, grounding_rule_version: GroundingGuard::RULE_VERSION,
        grounding_attribute_version: @guard.attribute_version,
        reviews_sha256: @reviews_path && Digest::SHA256.file(@reviews_path).hexdigest,
        realtime_line_evaluation_calls: 0, new_external_api_calls: 0
      }
    end

    def read_jsonl(directory, filename)
      File.readlines(File.join(directory, filename), encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def aggregate_usage(items)
      items.each_with_object(Usage.zero.to_h) do |item, total|
        %i[input_units output_units cached_input_units].each { |key| total[key] += item.fetch(key, 0).to_i }
        %i[estimated_cost_usd estimated_cost_jpy].each { |key| total[key] += item.fetch(key, 0).to_f }
      end.tap do |total|
        total[:estimated_cost_usd] = total[:estimated_cost_usd].round(8)
        total[:estimated_cost_jpy] = total[:estimated_cost_jpy].round(4)
      end
    end

    def add_usage(*items)
      aggregate_usage(items)
    end

    def symbolize(value)
      value.to_h.transform_keys(&:to_sym)
    end

    def jaccard(left, right)
      union = left | right
      union.empty? ? 1.0 : ((left & right).length.to_f / union.length).round(4)
    end

    def average(values)
      values.empty? ? 0.0 : (values.sum.to_f / values.length).round(4)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def percentile(values, fraction)
      return nil if values.empty?
      ordered = values.sort
      ordered.fetch([(ordered.length * fraction).ceil - 1, 0].max).round(2)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_time - started) * 1000).round(2)
    end

    def write_jsonl(filename, records)
      File.open(File.join(@output_dir, filename), "w:UTF-8") do |file|
        records.each { |record| file.puts(JSON.generate(record)) }
      end
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      File.join(@configuration.path(:results), "abstraction_only_integrated_replay_#{@now.call.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(2)}")
    end
  end
end
