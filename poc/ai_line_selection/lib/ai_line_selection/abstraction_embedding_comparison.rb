# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"

module AiLineSelection
  class AbstractionEmbeddingComparison
    VERSION = "abstraction-embedding-v1"
    MODES = %w[
      meaning_structure_baseline
      abstraction_only_v2
      abstraction_only_v2_line_centroid
    ].freeze
    DEFAULT_INPUTS_PATH = File.join("data", "abstractions", "abstraction_only_v2_repetitions.yml")

    attr_reader :output_dir

    def initialize(
      configuration:,
      allow_external_api: false,
      environment: ENV,
      transport: nil,
      progress: nil,
      now: -> { Time.now.utc },
      inputs_path: nil
    )
      @configuration = configuration
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @progress = progress || ->(_message) {}
      @now = now
      @data = DataLoader.new(configuration)
      @schemas = SchemaRegistry.new(root_dir: configuration.root_dir)
      @prompts = PromptRegistry.new(root_dir: configuration.root_dir)
      @text_builder = EmbeddingTextBuilder.new
      @inputs_path = File.expand_path(inputs_path || DEFAULT_INPUTS_PATH, configuration.root_dir)
      @additional_config_path = File.join(configuration.root_dir, "config", "additional_poc.yml")
      @inputs = load_yaml(@inputs_path)
      @additional_config = load_yaml(@additional_config_path)
      validate_inputs!
    end

    def plan(provider:, entry_ids: nil)
      context = comparison_context(provider, entry_ids)
      settings = context.fetch(:settings)
      estimated = planned_usage(context, ->(text) { [(text.length / 4.0).ceil, 1].max })
      maximum = planned_usage(context, ->(text) { [text.bytesize, 1].max })
      retry_multiplier = settings.fetch("max_retries", 0) + 1
      requests = MODES.length * 2
      {
        operation: VERSION,
        network_call_performed: false,
        modes: MODES,
        entry_count: context.fetch(:entries).length,
        approved_line_count: context.fetch(:approved_lines).length,
        excluded_before_embedding: status_counts(context.fetch(:excluded_lines)),
        abstraction_entry_repetitions: @inputs.fetch("repetitions"),
        fixed_line_abstraction_repetition: @inputs.fetch("line_index_repetition"),
        limits: limits,
        similarity_thresholds: thresholds,
        provider: provider_manifest(settings),
        total_requests: requests,
        maximum_requests_with_retries: requests * retry_multiplier,
        estimated_input_units: estimated.fetch(:input_units),
        estimated_cost_jpy: estimated.fetch(:estimated_cost_jpy),
        maximum_input_units_from_utf8_bytes: maximum.fetch(:input_units),
        maximum_cost_with_retries_jpy: (maximum.fetch(:estimated_cost_jpy) * retry_multiplier).round(4),
        configured_budget_jpy: @configuration.external_api.fetch("total_budget_jpy"),
        external_api_flag_required: settings.fetch("adapter") != "fixture",
        synthetic_data_only: true
      }
    end

    def call(provider:, entry_ids: nil, output_dir: nil)
      context = comparison_context(provider, entry_ids)
      ensure_external_api_allowed!(context.fetch(:settings))
      preflight = plan(provider: provider, entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") })
      enforce_budget!(preflight.fetch(:maximum_cost_with_retries_jpy))
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      client = OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@output_dir, "telemetry.jsonl")),
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )

      results = MODES.to_h do |mode|
        @progress.call("embedding #{mode} line index")
        result = execute_mode(client, mode, context)
        result.fetch(:records).each { |record| append_jsonl("candidate_sets.jsonl", record) }
        [mode, result]
      end
      usage = add_usage(*results.values.map { |result| result.fetch(:usage) })
      enforce_budget!(usage.fetch(:estimated_cost_jpy))
      write_blind_evaluation(results, context)
      summary = {
        operation: VERSION,
        completed: true,
        provider: provider_manifest(context.fetch(:settings)),
        entry_count: context.fetch(:entries).length,
        source_line_count: @data.lines.length,
        indexed_line_count: context.fetch(:approved_lines).length,
        excluded_before_embedding: status_counts(context.fetch(:excluded_lines)),
        limits: limits,
        similarity_thresholds: thresholds,
        modes: results.transform_values { |result| result.fetch(:summary) },
        comparison: compare_modes(results),
        usage: usage,
        blind_candidate_evaluation_pending: true,
        adoption_criteria: adoption_criteria(results)
      }
      write_manifest(context, preflight)
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json("stopped.json", { stopped_at: @now.call.iso8601, error_code: e.code }) if @output_dir
      raise
    end

    private

    def comparison_context(provider, entry_ids)
      settings = @configuration.embedding_provider(provider)
      entries = selected_entries(entry_ids)
      approved_lines = @data.lines.select { |line| line.fetch("status") == "approved" }
      excluded_lines = @data.lines.reject { |line| line.fetch("status") == "approved" }
      requests = MODES.length * 2
      maximum = @configuration.external_api.fetch("maximum_embedding_comparison_requests")
      if requests > maximum
        raise ConfigurationError.new(
          "Abstraction Embedding comparison exceeds the request limit",
          details: { requested: requests, maximum: maximum }
        )
      end
      {
        provider: provider,
        settings: settings,
        entries: entries,
        approved_lines: approved_lines,
        excluded_lines: excluded_lines
      }
    end

    def execute_mode(client, mode, context)
      settings = context.fetch(:settings)
      line_texts = line_embedding_texts(mode, context.fetch(:approved_lines))
      entry_descriptors = entry_descriptors(mode, context.fetch(:entries))
      entry_texts = entry_descriptors.map { |descriptor| descriptor.fetch(:text) }
      line_invocation = client.call(:embedding, { "texts" => line_texts }, settings: settings)
      @progress.call("embedding #{mode} entries")
      entry_invocation = client.call(:embedding, { "texts" => entry_texts }, settings: settings)
      raw_line_vectors = values(line_invocation)
      entry_vectors = values(entry_invocation)
      dimensions = validate_dimensions!(raw_line_vectors, entry_vectors, settings)
      line_vectors = aggregate_line_vectors(mode, raw_line_vectors, context.fetch(:approved_lines).length)
      search_durations = []
      records = entry_descriptors.each_with_index.map do |descriptor, index|
        started_at = monotonic_time
        ranked = search(entry_vectors.fetch(index), context.fetch(:approved_lines), line_vectors)
        repeated = search(entry_vectors.fetch(index), context.fetch(:approved_lines), line_vectors)
        search_durations << elapsed_ms(started_at)
        build_record(mode, descriptor, ranked, repeated)
      end
      usage = add_usage(line_invocation.metadata.fetch(:usage), entry_invocation.metadata.fetch(:usage))
      {
        records: records,
        usage: usage,
        summary: summarize_mode(
          mode,
          records,
          settings,
          dimensions,
          usage,
          line_invocation,
          entry_invocation,
          search_durations,
          context.fetch(:approved_lines).length,
          raw_line_vectors.length
        )
      }
    end

    def entry_descriptors(mode, entries)
      entries.flat_map do |entry|
        if mode == "meaning_structure_baseline"
          [{ entry: entry, repetition: 1, text: @text_builder.entry_text(entry, "meaning_structure") }]
        else
          input_item(entry.fetch("id")).fetch("repetitions").map do |repetition|
            {
              entry: entry,
              repetition: repetition.fetch("repetition"),
              text: normalize(repetition.fetch("abstraction"))
            }
          end
        end
      end
    end

    def embedding_text(mode, id, line:)
      return @text_builder.line_text(line, "meaning_structure") if mode == "meaning_structure_baseline"

      repetition = @inputs.fetch("line_index_repetition")
      record = input_item(id).fetch("repetitions").find { |item| item.fetch("repetition") == repetition }
      normalize(record.fetch("abstraction"))
    end

    def line_embedding_texts(mode, lines)
      return lines.map { |line| embedding_text(mode, line.fetch("id"), line: line) } unless centroid_mode?(mode)

      lines.flat_map do |line|
        input_item(line.fetch("id")).fetch("repetitions").map do |record|
          normalize(record.fetch("abstraction"))
        end
      end
    end

    def aggregate_line_vectors(mode, vectors, line_count)
      return vectors unless centroid_mode?(mode)

      repetition_count = Integer(@inputs.fetch("repetitions"))
      unless vectors.length == line_count * repetition_count
        raise ProviderContractError.new(
          "Line repetition vector count does not match inputs",
          operation: :embedding,
          details: { lines: line_count, repetitions: repetition_count, vectors: vectors.length }
        )
      end
      vectors.each_slice(repetition_count).map do |items|
        dimensions = items.first.length
        Array.new(dimensions) do |index|
          items.sum { |vector| vector.fetch(index) }.to_f / items.length
        end
      end
    end

    def search(vector, lines, line_vectors)
      CandidateSearch.new.search(
        query_vector: vector,
        lines: lines,
        line_vectors: line_vectors,
        limit: lines.length
      )
    end

    def build_record(mode, descriptor, ranked, repeated)
      entry = descriptor.fetch(:entry)
      relevant_ids = ranked.filter_map do |candidate|
        line = candidate.fetch("line")
        line.fetch("id") if entry.fetch("expected").fetch("themes").include?(line.fetch("theme"))
      end
      ranks_by_id = ranked.each_with_index.to_h { |candidate, index| [candidate.fetch("line").fetch("id"), index + 1] }
      relevant_ranks = relevant_ids.map { |id| ranks_by_id.fetch(id) }.sort
      top_candidates = ranked.first(limits.max).map.with_index do |candidate, index|
        line = candidate.fetch("line")
        {
          rank: index + 1,
          line_id: line.fetch("id"),
          theme: line.fetch("theme"),
          similarity: candidate.fetch("similarity"),
          expected_theme: entry.fetch("expected").fetch("themes").include?(line.fetch("theme"))
        }
      end
      {
        mode: mode,
        entry_id: entry.fetch("id"),
        repetition: descriptor.fetch(:repetition),
        deterministic_repeat_match: ranking_signature(ranked) == ranking_signature(repeated),
        relevant_line_count: relevant_ids.length,
        best_relevant_rank: relevant_ranks.first,
        mean_relevant_rank: average(relevant_ranks.sum, relevant_ranks.length),
        reciprocal_rank: relevant_ranks.empty? ? 0.0 : (1.0 / relevant_ranks.first).round(4),
        top_candidates: top_candidates,
        limits: limits.to_h do |limit|
          candidates = ranked.first(limit)
          candidate_ids = candidates.map { |candidate| candidate.dig("line", "id") }
          [
            limit.to_s,
            {
              candidate_ids: candidate_ids,
              returned_count: candidates.length,
              recall: ratio((candidate_ids & relevant_ids).length, relevant_ids.length),
              relevant_count: (candidate_ids & relevant_ids).length,
              status_exclusion_violations: candidates.count { |candidate| candidate.dig("line", "status") != "approved" }
            }
          ]
        end,
        thresholds: thresholds.to_h do |threshold|
          candidates = ranked.select { |candidate| candidate.fetch("similarity") >= threshold }
          [
            threshold_key(threshold),
            {
              candidate_ids: candidates.map { |candidate| candidate.dig("line", "id") },
              returned_count: candidates.length,
              empty: candidates.empty?,
              status_exclusion_violations: candidates.count { |candidate| candidate.dig("line", "status") != "approved" }
            }
          ]
        end
      }
    end

    def summarize_mode(
      mode,
      records,
      settings,
      dimensions,
      usage,
      line_invocation,
      entry_invocation,
      durations,
      indexed_count,
      line_embedding_count
    )
      representative = records.select { |record| record.fetch(:repetition) == 1 }
      status_violations = records.sum do |record|
        record.fetch(:limits).values.sum { |value| value.fetch(:status_exclusion_violations) } +
          record.fetch(:thresholds).values.sum { |value| value.fetch(:status_exclusion_violations) }
      end
      {
        model: settings.fetch("model"),
        dimensions: dimensions,
        vector_storage_bytes: (4 * dimensions) + 8,
        indexed_vector_storage_bytes: ((4 * dimensions) + 8) * indexed_count,
        indexed_line_count: indexed_count,
        line_embedding_count: line_embedding_count,
        line_vector_aggregation: centroid_mode?(mode) ? "arithmetic_centroid_of_three_abstractions" : "none",
        entry_embedding_count: records.length,
        entry_repetitions: records.map { |record| record.fetch(:repetition) }.uniq.sort,
        api_latency_ms: {
          line_index: line_invocation.metadata.fetch(:duration_ms),
          entry_batch: entry_invocation.metadata.fetch(:duration_ms)
        },
        search_latency_ms: {
          p50: percentile(durations, 0.50),
          p95: percentile(durations, 0.95),
          maximum: durations.max&.round(4)
        },
        usage: usage,
        deterministic_search_rate: ratio(records.count { |record| record.fetch(:deterministic_repeat_match) }, records.length),
        status_exclusion_violations: status_violations,
        ranking_diagnostics: {
          mean_best_relevant_rank: average(representative.sum { |record| record.fetch(:best_relevant_rank) }, representative.length),
          mean_reciprocal_rank: average(representative.sum { |record| record.fetch(:reciprocal_rank) }, representative.length),
          top_1_theme_mismatch_count: representative.count { |record| !record.dig(:top_candidates, 0, :expected_theme) },
          top_1_theme_mismatch_entry_ids: representative.filter_map do |record|
            record.fetch(:entry_id) unless record.dig(:top_candidates, 0, :expected_theme)
          end
        },
        limits: summarize_limits(representative),
        thresholds: summarize_thresholds(representative),
        generation_stability: mode.start_with?("abstraction_only_v2") ? summarize_stability(records) : nil
      }
    end

    def summarize_limits(records)
      limits.to_h do |limit|
        metrics = records.map { |record| record.dig(:limits, limit.to_s) }
        [
          limit.to_s,
          {
            average_recall: average(metrics.sum { |metric| metric.fetch(:recall) }, metrics.length),
            minimum_recall: metrics.map { |metric| metric.fetch(:recall) }.min,
            entries_with_relevant_theme: metrics.count { |metric| metric.fetch(:relevant_count).positive? },
            entries_with_relevant_theme_rate: ratio(metrics.count { |metric| metric.fetch(:relevant_count).positive? }, metrics.length),
            status_exclusion_violations: metrics.sum { |metric| metric.fetch(:status_exclusion_violations) }
          }
        ]
      end
    end

    def summarize_thresholds(records)
      thresholds.to_h do |threshold|
        key = threshold_key(threshold)
        metrics = records.map { |record| record.dig(:thresholds, key) }
        sizes = metrics.map { |metric| metric.fetch(:returned_count) }
        [
          key,
          {
            average_candidate_count: average(sizes.sum, sizes.length),
            minimum_candidate_count: sizes.min,
            maximum_candidate_count: sizes.max,
            empty_entry_count: metrics.count { |metric| metric.fetch(:empty) },
            empty_entry_rate: ratio(metrics.count { |metric| metric.fetch(:empty) }, metrics.length),
            status_exclusion_violations: metrics.sum { |metric| metric.fetch(:status_exclusion_violations) }
          }
        ]
      end
    end

    def summarize_stability(records)
      grouped = records.group_by { |record| record.fetch(:entry_id) }
      per_limit = limits.to_h do |limit|
        entry_metrics = grouped.map do |entry_id, items|
          pairs = items.combination(2).to_a
          jaccards = pairs.map do |left, right|
            jaccard(left.dig(:limits, limit.to_s, :candidate_ids), right.dig(:limits, limit.to_s, :candidate_ids))
          end
          rank_changes = pairs.map do |left, right|
            mean_rank_change(
              left.dig(:limits, limit.to_s, :candidate_ids),
              right.dig(:limits, limit.to_s, :candidate_ids),
              limit
            )
          end
          {
            entry_id: entry_id,
            jaccard: average(jaccards.sum, jaccards.length),
            mean_rank_change: average(rank_changes.sum, rank_changes.length)
          }
        end
        [
          limit.to_s,
          {
            average_jaccard: average(entry_metrics.sum { |metric| metric.fetch(:jaccard) }, entry_metrics.length),
            minimum_entry_jaccard: entry_metrics.map { |metric| metric.fetch(:jaccard) }.min,
            entries_at_or_above_0_80: entry_metrics.count { |metric| metric.fetch(:jaccard) >= 0.80 },
            average_mean_rank_change: average(entry_metrics.sum { |metric| metric.fetch(:mean_rank_change) }, entry_metrics.length),
            below_0_80_entry_ids: entry_metrics.filter_map do |metric|
              metric.fetch(:entry_id) if metric.fetch(:jaccard) < 0.80
            end
          }
        ]
      end
      { pairwise_by_limit: per_limit }
    end

    def compare_modes(results)
      baseline = results.fetch("meaning_structure_baseline").dig(:summary)
      abstractions = results.reject { |mode, _result| mode == "meaning_structure_baseline" }
      {
        top_n_diagnostics: abstractions.to_h do |mode, result|
          abstraction = result.fetch(:summary)
          [
            mode,
            limits.to_h do |limit|
              key = limit.to_s
              [
                key,
                {
                  baseline_theme_recall: baseline.dig(:limits, key, :average_recall),
                  abstraction_theme_recall: abstraction.dig(:limits, key, :average_recall),
                  difference: (
                    abstraction.dig(:limits, key, :average_recall) - baseline.dig(:limits, key, :average_recall)
                  ).round(4)
                }
              ]
            end
          ]
        end,
        candidate_retired_mixing_count: MODES.sum { |mode| results.fetch(mode).dig(:summary, :status_exclusion_violations) },
        realtime_line_evaluation_calls: 0,
        production_decision: "pending_blind_candidate_evaluation"
      }
    end

    def adoption_criteria(results)
      abstraction_modes = results.reject { |mode, _result| mode == "meaning_structure_baseline" }
      jaccards = abstraction_modes.transform_values do |result|
        result.dig(:summary, :generation_stability, :pairwise_by_limit, "20", :average_jaccard)
      end
      recommended_mode, top20_jaccard = jaccards.max_by { |_mode, value| value }
      {
        candidate_or_retired_mixing_zero: results.values.all? { |result| result.dig(:summary, :status_exclusion_violations).zero? },
        fixed_abstraction_search_determinism_100_percent: results.values.all? do |result|
          result.dig(:summary, :deterministic_search_rate) == 1.0
        end,
        repeated_abstraction_top20_jaccard_at_least_0_80: top20_jaccard >= 0.80,
        best_stability_mode: recommended_mode,
        best_top20_jaccard: top20_jaccard,
        entries_with_acceptable_candidate_at_least_95_percent: nil,
        blind_candidate_quality_pending: true,
        eligible_for_ruby_selection_comparison: false
      }
    end

    def write_blind_evaluation(results, context)
      mapping_rows = []
      evaluation_rows = []
      records_by_mode = results.transform_values do |result|
        result.fetch(:records).select { |record| record.fetch(:repetition) == 1 }.to_h do |record|
          [record.fetch(:entry_id), record]
        end
      end
      context.fetch(:entries).each do |entry|
        entry_id = entry.fetch("id")
        mode_order = blind_mode_order(entry_id)
        mode_order.each_with_index do |mode, index|
          blind_set_id = "#{entry_id}-#{('A'.ord + index).chr}"
          mapping_rows << [blind_set_id, entry_id, mode]
          records_by_mode.fetch(mode).fetch(entry_id).fetch(:top_candidates).first(20).each do |candidate|
            line = lines_by_id.fetch(candidate.fetch(:line_id))
            evaluation_rows << [
              blind_set_id,
              entry_id,
              candidate.fetch(:rank),
              candidate.fetch(:line_id),
              entry.fetch("body"),
              line.fetch("text"),
              "",
              "",
              "",
              "",
              "",
              ""
            ]
          end
        end
      end
      CSV.open(File.join(@output_dir, "blind_mapping.csv"), "w:UTF-8") do |csv|
        csv << %w[blind_set_id entry_id mode]
        mapping_rows.each { |row| csv << row }
      end
      CSV.open(File.join(@output_dir, "blind_candidate_evaluation.csv"), "w:UTF-8") do |csv|
        csv << %w[
          blind_set_id entry_id rank line_id entry_text line_text acceptable distance clearly_unrelated
          fatal_grounding_mismatch confidence reason
        ]
        evaluation_rows.each { |row| csv << row }
      end
    end

    def write_manifest(context, preflight)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601,
          operation: VERSION,
          source: "synthetic",
          provider: provider_manifest(context.fetch(:settings)),
          modes: MODES,
          entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") },
          approved_line_ids: context.fetch(:approved_lines).map { |line| line.fetch("id") },
          excluded_line_ids: context.fetch(:excluded_lines).map { |line| line.fetch("id") },
          limits: limits,
          similarity_thresholds: thresholds,
          random_seed: @configuration.random_seed,
          hashes: {
            entries: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
            lines: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
            abstraction_inputs: Digest::SHA256.file(@inputs_path).hexdigest,
            additional_poc_config: Digest::SHA256.file(@additional_config_path).hexdigest
          },
          abstraction_input: @inputs.slice(
            "comparison_version",
            "prompt_sha256",
            "schema_sha256",
            "provider",
            "model",
            "repetitions",
            "line_index_repetition"
          ),
          preflight: preflight
        }
      )
    end

    def validate_inputs!
      unless @inputs.fetch("comparison_version") == "abstraction-only-v2" && @inputs.fetch("source") == "synthetic"
        raise DataError.new("Abstraction Embedding inputs have an unsupported version")
      end
      unless @inputs.dig("review", "status") == "complete" && @inputs.dig("review", "human_review_required_count").zero?
        raise DataError.new("Abstraction Embedding inputs are not fully reviewed")
      end
      validate_hash!("entry_data_sha256", @configuration.path(:entries))
      validate_hash!("line_data_sha256", @configuration.path(:lines))
      expected = @data.entries.map { |entry| [entry.fetch("id"), "entry", "evaluation"] } +
                 @data.lines.map { |line| [line.fetch("id"), "line", line.fetch("status")] }
      actual = @inputs.fetch("items").map do |item|
        [item.fetch("id"), item.fetch("source_type"), item.fetch("source_status")]
      end
      raise DataError.new("Abstraction Embedding input IDs or statuses changed") unless actual == expected

      repetition_count = Integer(@inputs.fetch("repetitions"))
      @inputs.fetch("items").each do |item|
        repetitions = item.fetch("repetitions")
        unless repetitions.map { |record| record.fetch("repetition") } == (1..repetition_count).to_a
          raise DataError.new("Abstraction repetitions are incomplete", details: { id: item.fetch("id") })
        end
        unless repetitions.all? { |record| normalize(record.fetch("abstraction")).length.between?(2, 60) }
          raise DataError.new("Abstraction repetition length is invalid", details: { id: item.fetch("id") })
        end
      end
    rescue KeyError, TypeError, ArgumentError => e
      raise DataError.new("Abstraction Embedding inputs are invalid", details: { error_class: e.class.name })
    end

    def validate_hash!(field, path)
      expected = @inputs.fetch(field)
      actual = Digest::SHA256.file(path).hexdigest
      return if actual == expected

      raise DataError.new("Fixed data hash changed", details: { field: field, expected: expected, actual: actual })
    end

    def input_item(id)
      @input_items ||= @inputs.fetch("items").to_h { |item| [item.fetch("id"), item] }
      @input_items.fetch(id)
    end

    def lines_by_id
      @lines_by_id ||= @data.lines.to_h { |line| [line.fetch("id"), line] }
    end

    def selected_entries(entry_ids)
      return @data.entries if entry_ids.nil? || entry_ids.empty?

      Array(entry_ids).map { |id| @data.entry(id) }
    end

    def limits
      @limits ||= @additional_config.dig("embedding", "top_n_values").map { |value| Integer(value) }.sort.freeze
    end

    def thresholds
      @thresholds ||= @additional_config.dig("embedding", "similarity_thresholds").map { |value| Float(value) }.sort.freeze
    end

    def planned_usage(context, unit_counter)
      texts = MODES.flat_map do |mode|
        line_texts = line_embedding_texts(mode, context.fetch(:approved_lines))
        entry_texts = entry_descriptors(mode, context.fetch(:entries)).map { |descriptor| descriptor.fetch(:text) }
        line_texts + entry_texts
      end
      PricingCalculator.new(
        settings: context.fetch(:settings),
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(input_units: texts.sum { |text| unit_counter.call(text) }, output_units: 0).to_h
    end

    def values(invocation)
      invocation.value.fetch("vectors").map { |item| item.fetch("values") }
    end

    def validate_dimensions!(line_vectors, entry_vectors, settings)
      dimensions = (line_vectors + entry_vectors).map(&:length).uniq
      unless dimensions.length == 1 && dimensions.first == settings.fetch("dimensions")
        raise ProviderContractError.new(
          "Embedding dimensions do not match configuration",
          operation: :embedding,
          details: { expected: settings.fetch("dimensions"), actual: dimensions }
        )
      end
      dimensions.first
    end

    def ensure_external_api_allowed!(settings)
      return if settings.fetch("adapter") == "fixture" || @allow_external_api

      raise ExternalApiDisabledError.new(:embedding)
    end

    def enforce_budget!(cost_jpy)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: cost_jpy, limit_jpy: limit) if cost_jpy > limit
    end

    def provider_manifest(settings)
      settings.slice("adapter", "provider", "model", "dimensions", "timeout_seconds", "max_retries", "pricing")
    end

    def add_usage(*items)
      items.each_with_object(Usage.zero.to_h) do |usage, total|
        %i[input_units output_units cached_input_units].each { |key| total[key] += usage.fetch(key, 0).to_i }
        %i[estimated_cost_usd estimated_cost_jpy].each { |key| total[key] += usage.fetch(key, 0).to_f }
      end.tap do |total|
        total[:estimated_cost_usd] = total[:estimated_cost_usd].round(8)
        total[:estimated_cost_jpy] = total[:estimated_cost_jpy].round(4)
      end
    end

    def status_counts(lines)
      lines.map { |line| line.fetch("status") }.tally.sort.to_h
    end

    def ranking_signature(ranked)
      ranked.map { |candidate| [candidate.dig("line", "id"), candidate.fetch("similarity")] }
    end

    def blind_mode_order(entry_id)
      digest = Digest::SHA256.hexdigest("#{@configuration.random_seed}|#{entry_id}|#{VERSION}")
      MODES.rotate(digest[0, 8].to_i(16) % MODES.length)
    end

    def centroid_mode?(mode)
      mode == "abstraction_only_v2_line_centroid"
    end

    def threshold_key(value)
      format("%.2f", value)
    end

    def mean_rank_change(left, right, limit)
      union = left | right
      return 0.0 if union.empty?

      left_ranks = left.each_with_index.to_h { |id, index| [id, index + 1] }
      right_ranks = right.each_with_index.to_h { |id, index| [id, index + 1] }
      average(union.sum { |id| (left_ranks.fetch(id, limit + 1) - right_ranks.fetch(id, limit + 1)).abs }, union.length)
    end

    def jaccard(left, right)
      union = left | right
      return 1.0 if union.empty?

      ratio((left & right).length, union.length)
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
    end

    def load_yaml(path)
      YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    rescue Errno::ENOENT, Psych::Exception => e
      raise DataError.new("Abstraction Embedding YAML is invalid", details: { path: path, error_class: e.class.name })
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "abstraction_embedding_#{timestamp}_#{SecureRandom.hex(2)}")
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def percentile(values, fraction)
      return nil if values.empty?

      ordered = values.sort
      index = [(ordered.length * fraction).ceil - 1, 0].max
      ordered.fetch(index).round(4)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count)
      return 0.0 if count.zero?

      (total.to_f / count).round(4)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round(4)
    end
  end
end
