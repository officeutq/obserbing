# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"

module AiLineSelection
  class AbstractionComparison
    MAX_OUTPUT_TOKENS = 256
    SEMANTIC_REVIEW_COSINE_THRESHOLD = 0.85
    VERSIONS = {
      "abstraction-only-v1" => {
        prompt_file: "abstraction.md",
        schema_file: "abstraction.json"
      },
      "abstraction-only-v2" => {
        prompt_file: "abstraction_v2.md",
        schema_file: "abstraction_v2.json"
      }
    }.freeze

    attr_reader :output_dir

    def initialize(
      configuration:,
      allow_external_api: false,
      environment: ENV,
      transport: nil,
      progress: nil,
      now: -> { Time.now.utc },
      version: "abstraction-only-v1"
    )
      @configuration = configuration
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @progress = progress || ->(_message) {}
      @now = now
      @version = version.to_s
      version_files = VERSIONS.fetch(@version) do
        raise ConfigurationError.new("Unknown abstraction version", details: { version: @version })
      end
      @data = DataLoader.new(configuration)
      @schemas = SchemaRegistry.new(
        root_dir: configuration.root_dir,
        files: { abstraction: version_files.fetch(:schema_file) }
      )
      @prompts = PromptRegistry.new(
        root_dir: configuration.root_dir,
        files: { abstraction: version_files.fetch(:prompt_file) }
      )
    end

    def plan(provider:, embedding_provider:, repetitions:, item_ids: nil)
      context = context(provider, embedding_provider, repetitions, item_ids)
      abstraction_requests = context.fetch(:items).length * context.fetch(:repetitions)
      embedding_requests = 1
      maximum_requests = abstraction_requests * (context.fetch(:settings).fetch("max_retries") + 1) +
                         embedding_requests * (context.fetch(:embedding_settings).fetch("max_retries") + 1)
      maximum_cost = maximum_cost(context)
      {
        operation: operation_name,
        network_call_performed: false,
        item_count: context.fetch(:items).length,
        source_counts: context.fetch(:items).map { |item| item.fetch("source_type") }.tally,
        repetitions: context.fetch(:repetitions),
        provider: safe_settings(context.fetch(:settings)),
        semantic_embedding_provider: safe_settings(context.fetch(:embedding_settings)),
        abstraction_requests: abstraction_requests,
        semantic_embedding_requests: embedding_requests,
        total_requests: abstraction_requests + embedding_requests,
        maximum_requests_with_retries: maximum_requests,
        maximum_cost_with_retries_jpy: maximum_cost,
        configured_budget_jpy: budget,
        semantic_review_cosine_threshold: SEMANTIC_REVIEW_COSINE_THRESHOLD,
        external_api_flag_required: external?(context),
        synthetic_data_only: true
      }
    end

    def call(provider:, embedding_provider:, repetitions:, item_ids: nil, output_dir: nil)
      run_context = context(provider, embedding_provider, repetitions, item_ids)
      ensure_external_allowed!(run_context)
      planned = plan(
        provider: provider,
        embedding_provider: embedding_provider,
        repetitions: repetitions,
        item_ids: item_ids
      )
      if planned.fetch(:total_requests) > @configuration.external_api.fetch("maximum_abstraction_comparison_requests")
        raise ConfigurationError.new(
          "Abstraction comparison exceeds the configured request limit",
          details: {
            requested: planned.fetch(:total_requests),
            maximum: @configuration.external_api.fetch("maximum_abstraction_comparison_requests")
          }
        )
      end
      if planned.fetch(:maximum_cost_with_retries_jpy) > budget
        raise BudgetExceededError.new(
          estimated_cost_jpy: planned.fetch(:maximum_cost_with_retries_jpy),
          limit_jpy: budget
        )
      end

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

      records = generate_abstractions(client, run_context)
      embedding = generate_semantic_embeddings(client, run_context, records)
      summary = build_summary(run_context, records, embedding)
      write_artifacts(run_context, records, embedding, summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json("stopped.json", {
        stopped_at: @now.call.iso8601,
        error_code: e.code,
        attempts: client&.last_attempts || []
      }) if @output_dir
      raise
    end

    private

    def context(provider, embedding_provider, repetitions, item_ids)
      repetition_count = Integer(repetitions)
      maximum = @configuration.external_api.fetch("maximum_repetitions")
      unless repetition_count.between?(1, maximum)
        raise ConfigurationError.new(
          "Abstraction repetitions are outside the allowed range",
          details: { repetitions: repetition_count, maximum: maximum }
        )
      end

      available = all_items
      selected = if item_ids.nil? || item_ids.empty?
                   available
                 else
                   by_id = available.to_h { |item| [item.fetch("id"), item] }
                   Array(item_ids).map do |id|
                     by_id.fetch(id.to_s) do
                       raise DataError.new("Unknown abstraction item", details: { id: id.to_s })
                     end
                   end
                 end
      {
        provider: provider.to_s,
        embedding_provider: embedding_provider.to_s,
        settings: abstraction_settings(provider),
        embedding_settings: @configuration.embedding_provider(embedding_provider),
        repetitions: repetition_count,
        items: selected
      }
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Abstraction repetitions must be an integer")
    end

    def all_items
      @all_items ||= begin
        entries = @data.entries.map do |entry|
          {
            "id" => entry.fetch("id"),
            "source_type" => "entry",
            "text" => entry.fetch("body"),
            "baseline_abstraction" => entry.fetch("expected").fetch("abstraction"),
            "status" => "evaluation"
          }
        end
        lines = @data.lines.map do |line|
          {
            "id" => line.fetch("id"),
            "source_type" => "line",
            "text" => line.fetch("text"),
            "baseline_abstraction" => line.fetch("meaning"),
            "status" => line.fetch("status")
          }
        end
        (entries + lines).freeze
      end
    end

    def abstraction_settings(provider)
      name = provider.to_s
      base = if name == "fixture"
               @configuration.operation(:abstraction).merge(
                 "max_retries" => 0,
                 "pricing" => offline_pricing
               )
             else
               @configuration.meaning_provider(name)
             end
      base.merge(
        "max_output_tokens" => MAX_OUTPUT_TOKENS,
        "prompt_version" => @version,
        "schema_version" => @version
      )
    end

    def offline_pricing
      {
        "version" => "offline",
        "checked_at" => @now.call.strftime("%Y-%m-%d"),
        "input_per_million_usd" => 0.0,
        "cached_input_per_million_usd" => 0.0,
        "output_per_million_usd" => 0.0,
        "source" => "local-fixture"
      }
    end

    def generate_abstractions(client, run_context)
      records = []
      run_context.fetch(:items).each do |item|
        run_context.fetch(:repetitions).times do |index|
          @progress.call("abstraction #{item.fetch("source_type")} #{item.fetch("id")} #{index + 1}/#{run_context.fetch(:repetitions)}")
          invocation = client.call(
            :abstraction,
            { "text" => item.fetch("text") },
            fixture_context: item,
            settings: run_context.fetch(:settings)
          )
          record = {
            item_id: item.fetch("id"),
            source_type: item.fetch("source_type"),
            status: item.fetch("status"),
            repetition: index + 1,
            provider: run_context.fetch(:provider),
            model: invocation.metadata.fetch(:model),
            request_id: invocation.metadata.fetch(:request_id),
            abstraction: invocation.value.fetch("abstraction"),
            character_length: invocation.value.fetch("abstraction").length,
            attempt_count: invocation.metadata.fetch(:attempt_count),
            retry_count: invocation.metadata.fetch(:retry_count),
            first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
            duration_ms: invocation.metadata.fetch(:duration_ms),
            usage: invocation.metadata.fetch(:usage)
          }
          records << record
          append_jsonl("provider_outputs.jsonl", record)
          ensure_actual_budget!(records, nil)
        end
      end
      records
    end

    def generate_semantic_embeddings(client, run_context, records)
      texts = records.map { |record| record.fetch(:abstraction) } +
              run_context.fetch(:items).map { |item| item.fetch("baseline_abstraction") }
      @progress.call("semantic embedding #{texts.length} abstractions")
      invocation = client.call(:embedding, { "texts" => texts }, settings: run_context.fetch(:embedding_settings))
      vectors = invocation.value.fetch("vectors").map { |item| item.fetch("values") }
      ensure_actual_budget!(records, invocation.metadata.fetch(:usage))
      {
        vectors: vectors,
        generated_count: records.length,
        usage: invocation.metadata.fetch(:usage),
        duration_ms: invocation.metadata.fetch(:duration_ms),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        model: invocation.metadata.fetch(:model),
        request_id: invocation.metadata.fetch(:request_id)
      }
    end

    def build_summary(run_context, records, embedding)
      stability = stability_metrics(run_context, records, embedding)
      usage = records.map { |record| symbolize(record.fetch(:usage)) }
      embedding_usage = symbolize(embedding.fetch(:usage))
      total_cost_jpy = usage.sum { |item| item.fetch(:estimated_cost_jpy) } + embedding_usage.fetch(:estimated_cost_jpy)
      total_cost_usd = usage.sum { |item| item.fetch(:estimated_cost_usd) } + embedding_usage.fetch(:estimated_cost_usd)
      lengths = records.map { |record| record.fetch(:character_length) }
      durations = records.map { |record| record.fetch(:duration_ms).to_f }
      {
        operation: operation_name,
        completed: true,
        item_count: run_context.fetch(:items).length,
        source_counts: run_context.fetch(:items).map { |item| item.fetch("source_type") }.tally,
        repetitions: run_context.fetch(:repetitions),
        provider: {
          name: run_context.fetch(:provider),
          model: records.first&.fetch(:model),
          executions: records.length,
          requests_including_retries: records.sum { |record| record.fetch(:attempt_count) },
          first_attempt_schema_success_rate: ratio(records.count { |record| record.fetch(:first_attempt_success) }, records.length),
          success_after_retry_count: records.count { |record| record.fetch(:retry_count).positive? },
          exact_stability: stability.fetch(:exact_stability),
          semantic_similarity_triage: stability.fetch(:semantic_similarity_triage),
          baseline_similarity: stability.fetch(:baseline_similarity),
          source_type_stability: stability.fetch(:source_type_stability),
          character_length: {
            minimum: lengths.min,
            p50: percentile(lengths, 0.50),
            p95: percentile(lengths, 0.95),
            maximum: lengths.max,
            empty_count: lengths.count(&:zero?),
            over_60_count: lengths.count { |value| value > 60 }
          },
          forbidden_output_field_count: 0,
          latency_ms: {
            p50: percentile(durations, 0.50),
            p95: percentile(durations, 0.95),
            maximum: durations.max&.round(2)
          },
          usage: aggregate_usage(usage)
        },
        semantic_embedding: {
          provider: run_context.fetch(:embedding_provider),
          model: embedding.fetch(:model),
          text_count: embedding.fetch(:vectors).length,
          duration_ms: embedding.fetch(:duration_ms),
          attempt_count: embedding.fetch(:attempt_count),
          first_attempt_success: embedding.fetch(:first_attempt_success),
          usage: embedding_usage
        },
        total_estimated_cost_usd: total_cost_usd.round(8),
        total_estimated_cost_jpy: total_cost_jpy.round(4),
        human_evaluation_pending: true,
        adoption_criteria: {
          initial_schema_success_at_least_99_percent: ratio(records.count { |record| record.fetch(:first_attempt_success) }, records.length) >= 0.99,
          retry_schema_success_100_percent: records.length == run_context.fetch(:items).length * run_context.fetch(:repetitions),
          semantic_equivalence_at_least_85_percent: nil,
          semantic_equivalence_pending: true,
          human_quality_pending: true
        }
      }
    end

    def stability_metrics(run_context, records, embedding)
      generated_vectors = embedding.fetch(:vectors).first(records.length)
      baseline_vectors = embedding.fetch(:vectors).drop(records.length)
      item_metrics = run_context.fetch(:items).each_with_index.map do |item, item_index|
        indexes = records.each_index.select { |index| records.fetch(index).fetch(:item_id) == item.fetch("id") }
        outputs = indexes.map { |index| records.fetch(index).fetch(:abstraction) }
        pairwise = indexes.combination(2).map do |left, right|
          cosine(generated_vectors.fetch(left), generated_vectors.fetch(right))
        end
        {
          item_id: item.fetch("id"),
          source_type: item.fetch("source_type"),
          exact: outputs.uniq.length == 1,
          pairwise_average: average(pairwise.sum, pairwise.length),
          pairwise_minimum: pairwise.min || 1.0,
          needs_semantic_review: !pairwise.empty? && pairwise.min < SEMANTIC_REVIEW_COSINE_THRESHOLD,
          baseline_similarity: cosine(generated_vectors.fetch(indexes.first), baseline_vectors.fetch(item_index))
        }
      end
      exact_count = item_metrics.count { |item| item.fetch(:exact) }
      above_threshold_count = item_metrics.count { |item| !item.fetch(:needs_semantic_review) }
      {
        exact_stability: {
          stable_items: exact_count,
          total_items: item_metrics.length,
          rate: ratio(exact_count, item_metrics.length)
        },
        semantic_similarity_triage: {
          review_below_cosine: SEMANTIC_REVIEW_COSINE_THRESHOLD,
          items_at_or_above_threshold: above_threshold_count,
          total_items: item_metrics.length,
          rate_at_or_above_threshold: ratio(above_threshold_count, item_metrics.length),
          pairwise_cosine_average: average(item_metrics.sum { |item| item.fetch(:pairwise_average) }, item_metrics.length),
          minimum_pairwise_cosine: item_metrics.map { |item| item.fetch(:pairwise_minimum) }.min&.round(4),
          review_item_ids: item_metrics.select { |item| item.fetch(:needs_semantic_review) }.map { |item| item.fetch(:item_id) },
          semantic_equivalence_pending: true
        },
        baseline_similarity: {
          representative_repetition: 1,
          cosine_average: average(item_metrics.sum { |item| item.fetch(:baseline_similarity) }, item_metrics.length),
          cosine_minimum: item_metrics.map { |item| item.fetch(:baseline_similarity) }.min&.round(4)
        },
        source_type_stability: item_metrics.group_by { |item| item.fetch(:source_type) }.transform_values do |items|
          {
            items: items.length,
            exact_rate: ratio(items.count { |item| item.fetch(:exact) }, items.length),
            rate_at_or_above_review_threshold: ratio(items.count { |item| !item.fetch(:needs_semantic_review) }, items.length),
            pairwise_cosine_average: average(items.sum { |item| item.fetch(:pairwise_average) }, items.length)
          }
        end,
        items: item_metrics
      }
    end

    def write_artifacts(run_context, records, embedding, summary)
      write_blind_evaluation(run_context, records)
      write_canonical_candidates(run_context, records)
      write_semantic_review(run_context, records, embedding)
      write_json("semantic_similarity_triage.json", stability_metrics(run_context, records, embedding).fetch(:items))
      write_json("manifest.json", manifest(run_context))
      write_json("summary.json", summary)
    end

    def write_semantic_review(run_context, records, embedding)
      metrics = stability_metrics(run_context, records, embedding).fetch(:items).to_h do |item|
        [item.fetch(:item_id), item]
      end
      headers = %w[
        item_id source_type abstraction_1 abstraction_2 abstraction_3
        pairwise_cosine_average pairwise_cosine_minimum needs_semantic_review
        semantic_equivalent confidence reason judge
      ]
      CSV.open(File.join(@output_dir, "semantic_review.csv"), "w:UTF-8", write_headers: true, headers: headers) do |csv|
        run_context.fetch(:items).each do |item|
          outputs = records.select { |record| record.fetch(:item_id) == item.fetch("id") }
                           .sort_by { |record| record.fetch(:repetition) }
                           .map { |record| record.fetch(:abstraction) }
          metric = metrics.fetch(item.fetch("id"))
          csv << [
            item.fetch("id"), item.fetch("source_type"), *outputs,
            metric.fetch(:pairwise_average), metric.fetch(:pairwise_minimum), metric.fetch(:needs_semantic_review)
          ]
        end
      end
    end

    def write_blind_evaluation(run_context, records)
      mapping_headers = %w[blind_id item_id source_type side_a side_b]
      evaluation_headers = %w[
        blind_id item_id source_type source_text candidate_a candidate_b
        usability_a usability_b abstraction_level_match_a abstraction_level_match_b
        excessive_concrete_a excessive_concrete_b meaning_loss_a meaning_loss_b
        new_quantity_a new_quantity_b new_person_a new_person_b new_object_a new_object_b
        new_event_a new_event_b new_causality_a new_causality_b diagnosis_a diagnosis_b
        fixed_emotion_or_personality_a fixed_emotion_or_personality_b
        unnecessary_proper_noun_a unnecessary_proper_noun_b confidence notes judge
      ]
      mappings = []
      CSV.open(File.join(@output_dir, "blind_evaluation.csv"), "w:UTF-8", write_headers: true, headers: evaluation_headers) do |csv|
        run_context.fetch(:items).each_with_index do |item, index|
          candidate = records.find do |record|
            record.fetch(:item_id) == item.fetch("id") && record.fetch(:repetition) == 1
          end.fetch(:abstraction)
          candidate_first = Digest::SHA256.hexdigest("#{@configuration.random_seed}|#{item.fetch("id")}|abstraction")[0, 16].to_i(16).even?
          a, b = candidate_first ? [candidate, item.fetch("baseline_abstraction")] : [item.fetch("baseline_abstraction"), candidate]
          side_a, side_b = candidate_first ? %w[candidate baseline] : %w[baseline candidate]
          blind_id = format("A%04d", index + 1)
          mappings << [blind_id, item.fetch("id"), item.fetch("source_type"), side_a, side_b]
          csv << [blind_id, item.fetch("id"), item.fetch("source_type"), item.fetch("text"), a, b]
        end
      end
      CSV.open(File.join(@output_dir, "blind_mapping.csv"), "w:UTF-8", write_headers: true, headers: mapping_headers) do |csv|
        mappings.each { |row| csv << row }
      end
    end

    def write_canonical_candidates(run_context, records)
      candidates = run_context.fetch(:items).map do |item|
        record = records.find do |candidate|
          candidate.fetch(:item_id) == item.fetch("id") && candidate.fetch(:repetition) == 1
        end
        {
          "id" => item.fetch("id"),
          "source_type" => item.fetch("source_type"),
          "source_status" => item.fetch("status"),
          "abstraction" => record.fetch(:abstraction),
          "prompt_version" => @version,
          "schema_version" => @version,
          "model" => record.fetch(:model),
          "review_status" => "pending"
        }
      end
      File.write(
        File.join(@output_dir, "canonical_candidates.yml"),
        YAML.dump({ "version" => 1, "source" => "synthetic", "abstractions" => candidates }),
        mode: "w:UTF-8"
      )
    end

    def manifest(run_context)
      {
        created_at: @now.call.iso8601,
        operation: operation_name,
        source: "synthetic",
        provider: safe_settings(run_context.fetch(:settings)),
        semantic_embedding_provider: safe_settings(run_context.fetch(:embedding_settings)),
        repetitions: run_context.fetch(:repetitions),
        item_ids: run_context.fetch(:items).map { |item| item.fetch("id") },
        entry_data_sha256: file_sha256(@configuration.path(:entries)),
        line_data_sha256: file_sha256(@configuration.path(:lines)),
        prompt_sha256: Digest::SHA256.hexdigest(@prompts.fetch(:abstraction)),
        schema_sha256: Digest::SHA256.hexdigest(JSON.generate(@schemas.fetch(:abstraction))),
        semantic_review_cosine_threshold: SEMANTIC_REVIEW_COSINE_THRESHOLD,
        external_api_flag_required: true,
        source_text_in_normal_logs: false,
        generated_line_text: false
      }
    end

    def maximum_cost(run_context)
      abstraction = run_context.fetch(:items).sum do |item|
        input_units = @prompts.fetch(:abstraction).bytesize + item.fetch("text").bytesize
        usage_cost(run_context.fetch(:settings), input_units, MAX_OUTPUT_TOKENS) *
          (run_context.fetch(:settings).fetch("max_retries") + 1) * run_context.fetch(:repetitions)
      end
      generated_maximum_bytes = run_context.fetch(:items).length * run_context.fetch(:repetitions) * 60 * 3
      baseline_bytes = run_context.fetch(:items).sum { |item| item.fetch("baseline_abstraction").bytesize }
      embedding = usage_cost(
        run_context.fetch(:embedding_settings),
        generated_maximum_bytes + baseline_bytes,
        0
      ) * (run_context.fetch(:embedding_settings).fetch("max_retries") + 1)
      (abstraction + embedding).round(4)
    end

    def usage_cost(settings, input_units, output_units)
      PricingCalculator.new(settings: settings, usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")).usage(
        input_units: input_units,
        output_units: output_units
      ).estimated_cost_jpy
    end

    def ensure_actual_budget!(records, extra_usage)
      total = records.sum { |record| symbolize(record.fetch(:usage)).fetch(:estimated_cost_jpy) }
      total += symbolize(extra_usage).fetch(:estimated_cost_jpy) if extra_usage
      raise BudgetExceededError.new(estimated_cost_jpy: total.round(4), limit_jpy: budget) if total > budget
    end

    def external?(run_context)
      run_context.fetch(:settings).fetch("adapter") != "fixture" ||
        run_context.fetch(:embedding_settings).fetch("adapter") != "fixture"
    end

    def ensure_external_allowed!(run_context)
      raise ExternalApiDisabledError.new(:abstraction) if external?(run_context) && !@allow_external_api
    end

    def budget
      @configuration.external_api.fetch("total_budget_jpy").to_f
    end

    def safe_settings(settings)
      settings.slice(
        "adapter", "provider", "model", "api", "reasoning_effort", "dimensions",
        "max_output_tokens", "timeout_seconds", "max_retries", "prompt_version", "schema_version", "pricing"
      )
    end

    def aggregate_usage(items)
      {
        input_units: items.sum { |item| item.fetch(:input_units) },
        output_units: items.sum { |item| item.fetch(:output_units) },
        cached_input_units: items.sum { |item| item.fetch(:cached_input_units) },
        estimated_cost_usd: items.sum { |item| item.fetch(:estimated_cost_usd) }.round(8),
        estimated_cost_jpy: items.sum { |item| item.fetch(:estimated_cost_jpy) }.round(4)
      }
    end

    def symbolize(value)
      value.to_h.transform_keys(&:to_sym)
    end

    def cosine(left, right)
      dot = left.zip(right).sum { |a, b| a * b }
      left_size = Math.sqrt(left.sum { |value| value * value })
      right_size = Math.sqrt(right.sum { |value| value * value })
      return 0.0 if left_size.zero? || right_size.zero?

      (dot / (left_size * right_size)).round(8)
    end

    def percentile(values, fraction)
      return nil if values.empty?

      ordered = values.sort
      ordered.fetch([(ordered.length * fraction).ceil - 1, 0].max).round(2)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count)
      return 0.0 if count.zero?

      (total.to_f / count).round(4)
    end

    def file_sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(
        @configuration.path(:results),
        "abstraction_#{@version.tr('-', '_')}_#{timestamp}_#{SecureRandom.hex(2)}"
      )
    end

    def operation_name
      @version.tr("-", "_")
    end
  end
end
