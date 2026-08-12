# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class EmbeddingComparison
    DEFAULT_LIMITS = [20, 50, 100].freeze
    TARGET_RECALL = { 20 => 0.85, 50 => 0.95 }.freeze
    PGVECTOR_SOURCE = "https://github.com/pgvector/pgvector"

    attr_reader :output_dir

    def initialize(
      configuration:,
      allow_external_api: false,
      environment: ENV,
      transport: nil,
      progress: nil,
      now: -> { Time.now.utc }
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
    end

    def plan(providers:, variants: EmbeddingTextBuilder::VARIANTS, limits: DEFAULT_LIMITS, entry_ids: nil)
      context = comparison_context(providers, variants, limits, entry_ids)
      provider_plans = context.fetch(:providers).to_h do |name|
        settings = @configuration.embedding_provider(name)
        usage = planned_usage(
          settings,
          context.fetch(:entries),
          context.fetch(:approved_lines),
          context.fetch(:variants),
          unit_counter: ->(text) { [(text.length / 4.0).ceil, 1].max }
        )
        maximum_usage = planned_usage(
          settings,
          context.fetch(:entries),
          context.fetch(:approved_lines),
          context.fetch(:variants),
          unit_counter: ->(text) { [text.bytesize, 1].max }
        )
        [
          name,
          {
            adapter: settings.fetch("adapter"),
            model: settings.fetch("model"),
            dimensions: settings.fetch("dimensions"),
            requests: context.fetch(:variants).length * 2,
            maximum_requests_with_retries: context.fetch(:variants).length * 2 * (settings.fetch("max_retries", 0) + 1),
            estimated_input_units: usage.fetch(:input_units),
            estimated_cost_usd: usage.fetch(:estimated_cost_usd),
            estimated_cost_jpy: usage.fetch(:estimated_cost_jpy),
            maximum_input_units_from_utf8_bytes: maximum_usage.fetch(:input_units),
            maximum_cost_with_one_retry_jpy: (maximum_usage.fetch(:estimated_cost_jpy) * (settings.fetch("max_retries", 0) + 1)).round(4),
            external_api: settings.fetch("adapter") != "fixture"
          }
        ]
      end
      maximum_cost = provider_plans.values.sum { |item| item.fetch(:maximum_cost_with_one_retry_jpy) }.round(4)

      {
        operation: "embedding",
        network_call_performed: false,
        text_builder_version: EmbeddingTextBuilder::VERSION,
        variants: context.fetch(:variants),
        limits: context.fetch(:limits),
        entry_count: context.fetch(:entries).length,
        approved_line_count: context.fetch(:approved_lines).length,
        excluded_before_embedding: status_counts(context.fetch(:excluded_lines)),
        providers: provider_plans,
        total_requests: provider_plans.values.sum { |item| item.fetch(:requests) },
        maximum_requests_with_retries: provider_plans.values.sum { |item| item.fetch(:maximum_requests_with_retries) },
        maximum_cost_with_one_retry_jpy: maximum_cost,
        configured_budget_jpy: @configuration.external_api.fetch("total_budget_jpy"),
        external_api_flag_required: provider_plans.values.any? { |item| item.fetch(:external_api) }
      }
    end

    def call(providers:, variants: EmbeddingTextBuilder::VARIANTS, limits: DEFAULT_LIMITS, entry_ids: nil, output_dir: nil)
      context = comparison_context(providers, variants, limits, entry_ids)
      ensure_external_api_allowed!(context.fetch(:providers))
      preflight = plan(
        providers: context.fetch(:providers),
        variants: context.fetch(:variants),
        limits: context.fetch(:limits),
        entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") }
      )
      enforce_budget!(preflight)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      telemetry = Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@output_dir, "telemetry.jsonl"))
      client = OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: telemetry,
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
      summaries = {}
      running_cost_jpy = 0.0

      context.fetch(:providers).each do |provider_name|
        settings = @configuration.embedding_provider(provider_name)
        summaries[provider_name] = {}
        context.fetch(:variants).each do |variant|
          @progress.call("embedding #{provider_name} #{variant}")
          result = execute_variant(client, settings, provider_name, variant, context)
          summaries.fetch(provider_name)[variant] = result.fetch(:summary)
          running_cost_jpy += result.dig(:summary, :usage, :estimated_cost_jpy)
          enforce_runtime_budget!(running_cost_jpy)
          result.fetch(:records).each do |record|
            append_jsonl("entry_results.jsonl", record)
          end
        end
      end

      summary = {
        operation: "embedding",
        completed: true,
        text_builder_version: EmbeddingTextBuilder::VERSION,
        variants: context.fetch(:variants),
        limits: context.fetch(:limits),
        entry_count: context.fetch(:entries).length,
        source_line_count: @data.lines.length,
        indexed_line_count: context.fetch(:approved_lines).length,
        excluded_before_embedding: status_counts(context.fetch(:excluded_lines)),
        providers: summaries,
        decision: build_decision(summaries),
        pgvector_assumptions: pgvector_assumptions(summaries)
      }
      write_manifest(context, preflight)
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json("stopped.json", { stopped_at: @now.call.iso8601, error_code: e.code }) if @output_dir
      raise
    end

    private

    def comparison_context(providers, variants, limits, entry_ids)
      provider_names = validate_providers(providers)
      selected_variants = validate_variants(variants)
      selected_limits = validate_limits(limits)
      entries = selected_entries(entry_ids)
      approved_lines = @data.lines.select { |line| line.fetch("status") == "approved" }
      excluded_lines = @data.lines.reject { |line| line.fetch("status") == "approved" }
      requested = provider_names.length * selected_variants.length * 2
      maximum = @configuration.external_api.fetch("maximum_embedding_comparison_requests")
      if requested > maximum
        raise ConfigurationError.new(
          "Embedding comparison exceeds the configured request limit",
          details: { requested: requested, maximum: maximum }
        )
      end

      {
        providers: provider_names,
        variants: selected_variants,
        limits: selected_limits,
        entries: entries,
        approved_lines: approved_lines,
        excluded_lines: excluded_lines
      }
    end

    def execute_variant(client, settings, provider_name, variant, context)
      entries = context.fetch(:entries)
      approved_lines = context.fetch(:approved_lines)
      line_texts = approved_lines.map { |line| @text_builder.line_text(line, variant) }
      entry_texts = entries.map { |entry| @text_builder.entry_text(entry, variant) }
      line_invocation = client.call(:embedding, { "texts" => line_texts }, settings: settings)
      entry_invocation = client.call(:embedding, { "texts" => entry_texts }, settings: settings)
      line_vectors = values(line_invocation)
      entry_vectors = values(entry_invocation)
      dimensions = validate_dimensions!(line_vectors, entry_vectors, settings)
      search_durations = []
      records = entries.each_with_index.map do |entry, index|
        started_at = monotonic_time
        ranked = CandidateSearch.new.search(
          query_vector: entry_vectors.fetch(index),
          lines: approved_lines,
          line_vectors: line_vectors,
          limit: approved_lines.length
        )
        search_durations << elapsed_ms(started_at)
        build_entry_record(provider_name, settings, variant, entry, ranked, context.fetch(:limits))
      end
      usage = add_usage(line_invocation.metadata.fetch(:usage), entry_invocation.metadata.fetch(:usage))

      {
        records: records,
        summary: summarize_variant(
          records,
          settings,
          dimensions,
          usage,
          line_invocation,
          entry_invocation,
          search_durations,
          approved_lines.length,
          context.fetch(:limits)
        )
      }
    end

    def build_entry_record(provider_name, settings, variant, entry, ranked, limits)
      relevant_ids = ranked.filter_map do |candidate|
        line = candidate.fetch("line")
        line.fetch("id") if entry.fetch("expected").fetch("themes").include?(line.fetch("theme"))
      end
      ranks_by_id = ranked.each_with_index.to_h { |candidate, index| [candidate.fetch("line").fetch("id"), index + 1] }
      relevant_ranks = relevant_ids.map { |id| ranks_by_id.fetch(id) }.sort
      per_limit = limits.to_h do |limit|
        candidates = ranked.first(limit)
        candidate_ids = candidates.map { |candidate| candidate.fetch("line").fetch("id") }
        mixed_status_count = candidates.count { |candidate| candidate.fetch("line").fetch("status") != "approved" }
        [
          limit.to_s,
          {
            returned_count: candidates.length,
            recall: ratio((candidate_ids & relevant_ids).length, relevant_ids.length),
            relevant_count: (candidate_ids & relevant_ids).length,
            status_exclusion_violations: mixed_status_count
          }
        ]
      end
      top = ranked.first

      {
        provider: provider_name,
        model: settings.fetch("model"),
        variant: variant,
        entry_id: entry.fetch("id"),
        expected_themes: entry.fetch("expected").fetch("themes"),
        relevant_line_count: relevant_ids.length,
        best_relevant_rank: relevant_ranks.first,
        mean_relevant_rank: average(relevant_ranks.sum, relevant_ranks.length, 4),
        reciprocal_rank: relevant_ranks.empty? ? 0.0 : (1.0 / relevant_ranks.first).round(4),
        top_candidate: top && {
          line_id: top.fetch("line").fetch("id"),
          theme: top.fetch("line").fetch("theme"),
          similarity: top.fetch("similarity"),
          expected_theme: entry.fetch("expected").fetch("themes").include?(top.fetch("line").fetch("theme"))
        },
        limits: per_limit
      }
    end

    def summarize_variant(records, settings, dimensions, usage, line_invocation, entry_invocation, search_durations, indexed_count, limits)
      limit_summaries = limits.to_h do |limit|
        values = records.map { |record| record.dig(:limits, limit.to_s, :recall) }
        target = TARGET_RECALL[limit]
        [
          limit.to_s,
          {
            average_recall: average(values.sum, values.length, 4),
            minimum_recall: values.min,
            entries_meeting_target: target && values.count { |value| value >= target },
            target_recall: target,
            status_exclusion_violations: records.sum { |record| record.dig(:limits, limit.to_s, :status_exclusion_violations) }
          }
        ]
      end
      vector_bytes = (4 * dimensions) + 8
      top_mismatches = records.reject { |record| record.dig(:top_candidate, :expected_theme) }.map { |record| record.fetch(:entry_id) }

      {
        model: settings.fetch("model"),
        dimensions: dimensions,
        vector_storage_bytes: vector_bytes,
        indexed_vector_storage_bytes: vector_bytes * indexed_count,
        indexed_line_count: indexed_count,
        api_latency_ms: {
          line_index: line_invocation.metadata.fetch(:duration_ms),
          entry_batch: entry_invocation.metadata.fetch(:duration_ms)
        },
        search_latency_ms: {
          p50: percentile(search_durations, 0.50),
          p95: percentile(search_durations, 0.95),
          max: search_durations.max&.round(4)
        },
        usage: usage,
        usage_breakdown: {
          line_index: line_invocation.metadata.fetch(:usage),
          entry_batch: entry_invocation.metadata.fetch(:usage)
        },
        ranking: {
          mean_best_relevant_rank: average(records.sum { |record| record.fetch(:best_relevant_rank) }, records.length, 4),
          mean_relevant_rank: average(records.sum { |record| record.fetch(:mean_relevant_rank) }, records.length, 4),
          mean_reciprocal_rank: average(records.sum { |record| record.fetch(:reciprocal_rank) }, records.length, 4),
          top_1_theme_mismatch_count: top_mismatches.length,
          top_1_theme_mismatch_entry_ids: top_mismatches
        },
        limits: limit_summaries,
        smallest_limit_reaching_95_average_recall: limits.find do |limit|
          limit_summaries.dig(limit.to_s, :average_recall) >= 0.95
        end
      }
    end

    def build_decision(summaries)
      candidates = summaries.flat_map do |provider, variants|
        variants.map do |variant, summary|
          fixture = provider == "fixture"
          failures = TARGET_RECALL.filter_map do |limit, target|
            actual = summary.dig(:limits, limit.to_s, :average_recall)
            if actual.nil?
              "Recall@#{limit} was not evaluated"
            elsif actual < target
              "Recall@#{limit}=#{actual} is below #{target}"
            end
          end
          failures << "Fixture hash vectors are not semantic embeddings" if fixture
          {
            provider: provider,
            model: summary.fetch(:model),
            variant: variant,
            status: failures.empty? ? "eligible_for_poc_candidate" : "not_eligible",
            reasons: failures.empty? ? ["Predefined recall and status-exclusion criteria passed"] : failures,
            recall_at_20: summary.dig(:limits, "20", :average_recall),
            recall_at_50: summary.dig(:limits, "50", :average_recall),
            smallest_limit_reaching_95_average_recall: summary.fetch(:smallest_limit_reaching_95_average_recall),
            estimated_cost_jpy: summary.dig(:usage, :estimated_cost_jpy)
          }
        end
      end
      eligible = candidates.select { |candidate| candidate.fetch(:status) == "eligible_for_poc_candidate" }
      recommended = eligible.min_by do |candidate|
        [
          candidate.fetch(:smallest_limit_reaching_95_average_recall) || Float::INFINITY,
          candidate.fetch(:estimated_cost_jpy),
          -candidate.fetch(:recall_at_20).to_f,
          candidate.fetch(:provider),
          candidate.fetch(:variant)
        ]
      end

      {
        production_decision: "pending_integration_and_production_scale_validation",
        recommended_poc_candidate: recommended && recommended.slice(
          :provider,
          :model,
          :variant,
          :recall_at_20,
          :recall_at_50,
          :smallest_limit_reaching_95_average_recall,
          :estimated_cost_jpy
        ),
        candidates: candidates,
        similarity_only_limitations: [
          "Similarity does not judge whether a Line is too direct, too close, or leaves appropriate space",
          "Similarity does not enforce recent-use, reuse, or other application rules",
          "A relevant theme match is an evaluation proxy, not proof that the final Line is obserbing-like",
          "Approximate pgvector indexes require a separate exact-versus-ANN recall and latency check on production-scale data"
        ]
      }
    end

    def pgvector_assumptions(summaries)
      dimensions = summaries.values.flat_map { |variants| variants.values.map { |summary| summary.fetch(:dimensions) } }.uniq.sort
      {
        migration_created: false,
        distance: "cosine",
        candidate_index: "HNSW with vector_cosine_ops after production-scale measurement",
        dimensions_measured: dimensions,
        vector_dimension_limit_for_hnsw: 2000,
        storage_formula: "4 * dimensions + 8 bytes per vector",
        filtering: "status = approved must be applied before indexing and in the database query",
        versioning: "model and embedding-text version must switch atomically; mixed versions are not searchable together",
        source: PGVECTOR_SOURCE
      }
    end

    def write_manifest(context, preflight)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601,
          operation: "embedding",
          providers: context.fetch(:providers).to_h do |name|
            [name, @configuration.embedding_provider(name).slice("adapter", "provider", "model", "dimensions", "pricing")]
          end,
          variants: context.fetch(:variants),
          limits: context.fetch(:limits),
          entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") },
          approved_line_ids: context.fetch(:approved_lines).map { |line| line.fetch("id") },
          text_builder_version: EmbeddingTextBuilder::VERSION,
          preflight: preflight,
          external_api_flag_required: preflight.fetch(:external_api_flag_required)
        }
      )
    end

    def planned_usage(settings, entries, lines, variants, unit_counter:)
      input_units = variants.sum do |variant|
        texts = entries.map { |entry| @text_builder.entry_text(entry, variant) } +
                lines.map { |line| @text_builder.line_text(line, variant) }
        texts.sum { |text| unit_counter.call(text) }
      end
      PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(input_units: input_units, output_units: 0).to_h
    end

    def validate_providers(providers)
      names = Array(providers).map(&:to_s).reject(&:empty?).uniq
      raise ConfigurationError.new("At least one Embedding provider is required") if names.empty?

      unknown = names - @configuration.embedding_provider_names
      raise ConfigurationError.new("Unknown Embedding providers", details: { providers: unknown }) unless unknown.empty?
      names
    end

    def validate_variants(variants)
      names = Array(variants).map(&:to_s).reject(&:empty?).uniq
      raise ConfigurationError.new("At least one Embedding variant is required") if names.empty?

      unknown = names - EmbeddingTextBuilder::VARIANTS
      raise ConfigurationError.new("Unknown Embedding variants", details: { variants: unknown }) unless unknown.empty?
      names
    end

    def validate_limits(limits)
      values = Array(limits).map { |value| Integer(value) }.uniq.sort
      raise ConfigurationError.new("At least one positive candidate limit is required") if values.empty? || values.any? { |value| value <= 0 }
      values
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Embedding candidate limits must be integers")
    end

    def selected_entries(entry_ids)
      return @data.entries if entry_ids.nil? || entry_ids.empty?

      Array(entry_ids).map { |id| @data.entry(id) }
    end

    def ensure_external_api_allowed!(providers)
      external = providers.any? { |name| @configuration.embedding_provider(name).fetch("adapter") != "fixture" }
      raise ExternalApiDisabledError.new(:embedding) if external && !@allow_external_api
    end

    def enforce_budget!(preflight)
      estimate = preflight.fetch(:maximum_cost_with_one_retry_jpy)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: estimate, limit_jpy: limit) if estimate > limit
    end

    def enforce_runtime_budget!(cost_jpy)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: cost_jpy.round(4), limit_jpy: limit) if cost_jpy > limit
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

    def values(invocation)
      invocation.value.fetch("vectors").map { |item| item.fetch("values") }
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

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "embedding_#{timestamp}_#{SecureRandom.hex(2)}")
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

    def average(total, count, precision)
      return nil if count.zero?

      (total.to_f / count).round(precision)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round(4)
    end
  end
end
