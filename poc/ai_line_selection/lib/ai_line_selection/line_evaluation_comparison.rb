# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class LineEvaluationComparison
    EMBEDDING_VARIANT = "meaning_structure"
    DEFAULT_EMBEDDING_PROVIDER = "openai-small"
    PROVIDER_PROMPT_OVERHEAD_RESERVE = 2048

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

    def plan(providers:, repetitions:, entry_ids: nil, embedding_provider: DEFAULT_EMBEDDING_PROVIDER)
      context = comparison_context(providers, repetitions, entry_ids, embedding_provider)
      embedding = embedding_plan(context)
      evaluators = context.fetch(:providers).to_h do |name|
        settings = @configuration.line_evaluation_provider(name)
        maximum = maximum_evaluation_usage(settings, context)
        requests = context.fetch(:entries).length * context.fetch(:repetitions)
        [
          name,
          {
            adapter: settings.fetch("adapter"),
            model: settings.fetch("model"),
            requests: requests,
            maximum_requests_with_retries: requests * (settings.fetch("max_retries") + 1),
            maximum_input_units_from_utf8_bytes: maximum.fetch(:input_units),
            maximum_output_units: maximum.fetch(:output_units),
            maximum_cost_with_one_retry_jpy: maximum.fetch(:estimated_cost_jpy),
            external_api: settings.fetch("adapter") != "fixture"
          }
        ]
      end
      maximum_cost = embedding.fetch(:maximum_cost_with_one_retry_jpy) +
                     evaluators.values.sum { |item| item.fetch(:maximum_cost_with_one_retry_jpy) }

      {
        operation: "line_evaluation",
        network_call_performed: false,
        entry_count: context.fetch(:entries).length,
        candidate_limit: context.fetch(:candidate_limit),
        repetitions: context.fetch(:repetitions),
        embedding: embedding,
        evaluators: evaluators,
        total_requests: embedding.fetch(:requests) + evaluators.values.sum { |item| item.fetch(:requests) },
        maximum_requests_with_retries: embedding.fetch(:maximum_requests_with_retries) +
          evaluators.values.sum { |item| item.fetch(:maximum_requests_with_retries) },
        maximum_cost_with_one_retry_jpy: maximum_cost.round(4),
        configured_budget_jpy: @configuration.external_api.fetch("total_budget_jpy"),
        external_api_flag_required: embedding.fetch(:external_api) ||
          evaluators.values.any? { |item| item.fetch(:external_api) },
        ai_and_rails_decisions_recorded_separately: true,
        technical_errors_are_not_silence: true
      }
    end

    def call(providers:, repetitions:, entry_ids: nil, embedding_provider: DEFAULT_EMBEDDING_PROVIDER, output_dir: nil)
      context = comparison_context(providers, repetitions, entry_ids, embedding_provider)
      ensure_external_api_allowed!(context)
      preflight = plan(
        providers: context.fetch(:providers),
        repetitions: context.fetch(:repetitions),
        entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") },
        embedding_provider: embedding_provider
      )
      enforce_budget!(preflight)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      client = build_client
      candidates, embedding_usage = build_candidate_sets(client, context)
      candidates.each { |item| append_jsonl("candidate_sets.jsonl", serialized_candidate_set(item)) }
      records = execute_evaluations(client, context, candidates, embedding_usage)
      summary = build_summary(context, records, embedding_usage)
      write_review_artifacts(context, records)
      write_manifest(context, preflight)
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json(
        "stopped.json",
        { stopped_at: @now.call.iso8601, error_code: e.code, semantic_silence: false }
      ) if @output_dir
      raise
    end

    private

    def comparison_context(providers, repetitions, entry_ids, embedding_provider)
      provider_names = Array(providers).map(&:to_s).reject(&:empty?).uniq
      raise ConfigurationError.new("At least one Line evaluation provider is required") if provider_names.empty?
      unknown = provider_names - @configuration.line_evaluation_provider_names
      unless unknown.empty?
        raise ConfigurationError.new("Unknown Line evaluation providers", details: { providers: unknown })
      end
      repetition_count = Integer(repetitions)
      maximum_repetitions = @configuration.external_api.fetch("maximum_repetitions")
      unless repetition_count.between?(1, maximum_repetitions)
        raise ConfigurationError.new(
          "Line evaluation repetitions are outside the allowed range",
          details: { repetitions: repetition_count, maximum: maximum_repetitions }
        )
      end
      entries = entry_ids.nil? || entry_ids.empty? ? @data.entries : Array(entry_ids).map { |id| @data.entry(id) }
      approved_lines = @data.lines.select { |line| line.fetch("status") == "approved" }
      embedding_settings = @configuration.embedding_provider(embedding_provider)
      requested = 2 + (provider_names.length * entries.length * repetition_count)
      maximum = @configuration.external_api.fetch("maximum_line_evaluation_comparison_requests")
      if requested > maximum
        raise ConfigurationError.new(
          "Line evaluation comparison exceeds the configured request limit",
          details: { requested: requested, maximum: maximum }
        )
      end

      {
        providers: provider_names,
        repetitions: repetition_count,
        entries: entries,
        approved_lines: approved_lines,
        embedding_provider: embedding_provider.to_s,
        embedding_settings: embedding_settings,
        candidate_limit: @configuration.search.fetch("evaluation_limit")
      }
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Line evaluation repetitions must be an integer")
    end

    def build_client
      OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@output_dir, "telemetry.jsonl")),
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
    end

    def build_candidate_sets(client, context)
      settings = context.fetch(:embedding_settings)
      lines = context.fetch(:approved_lines)
      entries = context.fetch(:entries)
      @progress.call("embedding #{context.fetch(:embedding_provider)} candidate sets")
      line_texts = lines.map { |line| @text_builder.line_text(line, EMBEDDING_VARIANT) }
      entry_texts = entries.map { |entry| @text_builder.entry_text(entry, EMBEDDING_VARIANT) }
      line_invocation = client.call(:embedding, { "texts" => line_texts }, settings: settings)
      entry_invocation = client.call(:embedding, { "texts" => entry_texts }, settings: settings)
      line_vectors = vector_values(line_invocation)
      entry_vectors = vector_values(entry_invocation)
      validate_embedding_dimensions!(line_vectors + entry_vectors, settings)
      sets = entries.each_with_index.map do |entry, index|
        ranked = CandidateSearch.new.search(
          query_vector: entry_vectors.fetch(index),
          lines: lines,
          line_vectors: line_vectors,
          limit: context.fetch(:candidate_limit)
        )
        { entry: entry, candidates: ranked }
      end
      [sets, add_usage(line_invocation.metadata.fetch(:usage), entry_invocation.metadata.fetch(:usage))]
    end

    def execute_evaluations(client, context, candidate_sets, embedding_usage)
      records = []
      context.fetch(:providers).each do |provider_name|
        settings = @configuration.line_evaluation_provider(provider_name)
        candidate_sets.each do |candidate_set|
          context.fetch(:repetitions).times do |index|
            entry = candidate_set.fetch(:entry)
            @progress.call("line_evaluation #{provider_name} #{entry.fetch("id")} #{index + 1}/#{context.fetch(:repetitions)}")
            input = evaluation_input(entry, candidate_set.fetch(:candidates))
            invocation = client.call(:line_evaluation, input, settings: settings)
            record = build_record(provider_name, entry, candidate_set.fetch(:candidates), invocation, index + 1)
            records << record
            append_jsonl("provider_outputs.jsonl", record)
            enforce_runtime_budget!(embedding_usage.fetch(:estimated_cost_jpy) + total_cost(records))
          end
        end
      end
      records
    end

    def evaluation_input(entry, candidates)
      {
        "meaning" => entry.fetch("expected").slice("themes", "structure", "abstraction"),
        "candidates" => candidates.map do |candidate|
          line = candidate.fetch("line")
          {
            "line" => line.slice("id", "text"),
            "similarity" => candidate.fetch("similarity")
          }
        end
      }
    end

    def build_record(provider_name, entry, candidates, invocation, repetition)
      output = invocation.value
      lines = candidates.map { |item| item.fetch("line") }
      policies = selection_policies.to_h do |name, settings|
        [name, FinalSelector.new(settings).explain(output.fetch("candidates"), lines)]
      end
      recommendation = output.fetch("recommended_line_id")
      ai_selection = recommendation == "SILENCE" ? silence_selection : line_selection(recommendation, lines)
      balanced = policies.fetch("balanced")
      {
        entry_id: entry.fetch("id"),
        repetition: repetition,
        provider: provider_name,
        model: invocation.metadata.fetch(:model),
        request_id: invocation.metadata.fetch(:request_id),
        status: "success",
        line_evaluation: output,
        ai_selection: ai_selection,
        rails_selection: balanced,
        ai_rails_same: ai_selection.fetch(:line_id) == balanced.fetch(:line_id),
        policy_selections: policies.transform_values { |value| value.slice(:status, :line_id, :final_score, :silence_reason, :qualified_count) },
        duration_ms: invocation.metadata.fetch(:duration_ms),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        retry_count: invocation.metadata.fetch(:retry_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        usage: invocation.metadata.fetch(:usage)
      }
    end

    def line_selection(line_id, lines)
      line = lines.find { |item| item.fetch("id") == line_id }
      { status: "line", line_id: line_id, line_text: line.fetch("text"), silence_reason: nil }
    end

    def silence_selection
      { status: "silence", line_id: nil, line_text: nil, silence_reason: "ai_no_qualified_candidate" }
    end

    def selection_policies
      configured = @configuration.selection.fetch("policies", {})
      return configured unless configured.empty?

      { "balanced" => @configuration.selection.slice(
        "minimum_relevance", "maximum_directness", "minimum_space", "minimum_obserbing_fit"
      ) }
    end

    def build_summary(context, records, embedding_usage)
      {
        operation: "line_evaluation",
        completed: true,
        entry_count: context.fetch(:entries).length,
        repetitions: context.fetch(:repetitions),
        candidate_limit: context.fetch(:candidate_limit),
        embedding: {
          provider: context.fetch(:embedding_provider),
          model: context.dig(:embedding_settings, "model"),
          variant: EMBEDDING_VARIANT,
          requests: 2,
          usage: embedding_usage
        },
        human_evaluation: {
          status: "pending_preliminary_review",
          representative_repetition: 1,
          low_confidence_only_human_review_supported: true
        },
        technical_errors_are_not_silence: true,
        providers: context.fetch(:providers).to_h do |name|
          provider_records = records.select { |record| record.fetch(:provider) == name }
          [name, provider_summary(provider_records, context)]
        end,
        total_estimated_cost_jpy: (embedding_usage.fetch(:estimated_cost_jpy) + total_cost(records)).round(4)
      }
    end

    def provider_summary(records, context)
      first = records.select { |record| record.fetch(:repetition) == 1 }
      usage = records.map { |record| symbolize(record.fetch(:usage)) }
      durations = records.map { |record| record.fetch(:duration_ms).to_f }
      stable = context.fetch(:entries).count do |entry|
        values = records.select { |record| record.fetch(:entry_id) == entry.fetch("id") }
                        .map { |record| record.dig(:rails_selection, :line_id) }
        values.length == context.fetch(:repetitions) && values.uniq.length == 1
      end
      {
        model: records.first&.fetch(:model),
        executions: records.length,
        first_attempt_schema_success_rate: ratio(records.count { |record| record.fetch(:first_attempt_success) }, records.length),
        retry_success_count: records.count { |record| record.fetch(:retry_count).positive? },
        ai_rails_same_rate: ratio(records.count { |record| record.fetch(:ai_rails_same) }, records.length),
        ai_silence_rate: ratio(records.count { |record| record.dig(:ai_selection, :status) == "silence" }, records.length),
        rails_silence_rate: ratio(records.count { |record| record.dig(:rails_selection, :status) == "silence" }, records.length),
        representative_ai_rails_differences: first.reject { |record| record.fetch(:ai_rails_same) }.map { |record| record.fetch(:entry_id) },
        exact_final_selection_stability: context.fetch(:repetitions) > 1 ? {
          stable_entries: stable,
          total_entries: context.fetch(:entries).length,
          rate: ratio(stable, context.fetch(:entries).length)
        } : nil,
        threshold_sensitivity: threshold_sensitivity(first),
        latency_ms: { p50: percentile(durations, 0.50), p95: percentile(durations, 0.95), max: durations.max&.round(2) },
        usage: sum_usage(usage)
      }
    end

    def threshold_sensitivity(records)
      names = selection_policies.keys
      {
        policies: names,
        silence_counts: names.to_h do |name|
          [name, records.count { |record| record.dig(:policy_selections, name, :status) == "silence" }]
        end,
        changed_from_balanced_entry_ids: names.reject { |name| name == "balanced" }.to_h do |name|
          [name, records.filter_map do |record|
            record.fetch(:entry_id) if record.dig(:policy_selections, name, :line_id) !=
              record.dig(:policy_selections, "balanced", :line_id)
          end]
        end
      }
    end

    def write_review_artifacts(context, records)
      representative = records.select { |record| record.fetch(:repetition) == 1 }
      blind = representative.shuffle(random: Random.new(@configuration.random_seed)).each_with_index.map do |record, index|
        [format("LE%03d", index + 1), record]
      end
      entries = context.fetch(:entries).to_h { |entry| [entry.fetch("id"), entry] }
      CSV.open(
        File.join(@output_dir, "human_evaluation.csv"),
        "w:UTF-8",
        write_headers: true,
        headers: %w[blind_id entry_id entry_body selected_line_id selected_line_text ai_line_id outcome distance_rating acceptable fatal_violation judge confidence reason needs_human_review human_reviewed notes]
      ) do |csv|
        blind.each do |blind_id, record|
          selection = record.fetch(:rails_selection)
          csv << [
            blind_id, record.fetch(:entry_id), entries.fetch(record.fetch(:entry_id)).fetch("body"),
            selection.fetch(:line_id), selection.fetch(:line_text), record.dig(:ai_selection, :line_id), selection.fetch(:status),
            nil, nil, nil, nil, nil, nil, "true", "false", nil
          ]
        end
      end
      CSV.open(
        File.join(@output_dir, "blind_mapping.csv"),
        "w:UTF-8",
        write_headers: true,
        headers: %w[blind_id entry_id repetition provider model request_id]
      ) do |csv|
        blind.each do |blind_id, record|
          csv << [blind_id, record.fetch(:entry_id), record.fetch(:repetition), record.fetch(:provider), record.fetch(:model), record.fetch(:request_id)]
        end
      end
    end

    def write_manifest(context, preflight)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601,
          operation: "line_evaluation",
          providers: context.fetch(:providers).to_h do |name|
            [name, @configuration.line_evaluation_provider(name).slice(
              "provider", "model", "api", "reasoning_effort", "max_output_tokens", "timeout_seconds", "max_retries", "pricing"
            )]
          end,
          embedding_provider: context.fetch(:embedding_provider),
          embedding_variant: EMBEDDING_VARIANT,
          repetitions: context.fetch(:repetitions),
          candidate_limit: context.fetch(:candidate_limit),
          entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") },
          approved_line_ids: context.fetch(:approved_lines).map { |line| line.fetch("id") },
          prompt_sha256: Digest::SHA256.hexdigest(@prompts.fetch(:line_evaluation)),
          schema_sha256: Digest::SHA256.hexdigest(JSON.generate(@schemas.fetch(:line_evaluation))),
          preflight: preflight,
          leaked_line_metadata: [],
          external_api_flag_required: preflight.fetch(:external_api_flag_required)
        }
      )
    end

    def serialized_candidate_set(item)
      {
        entry_id: item.fetch(:entry).fetch("id"),
        candidate_ids: item.fetch(:candidates).map { |candidate| candidate.fetch("line").fetch("id") },
        candidates: item.fetch(:candidates).map do |candidate|
          { line_id: candidate.fetch("line").fetch("id"), similarity: candidate.fetch("similarity") }
        end
      }
    end

    def embedding_plan(context)
      settings = context.fetch(:embedding_settings)
      texts = context.fetch(:approved_lines).map { |line| @text_builder.line_text(line, EMBEDDING_VARIANT) } +
              context.fetch(:entries).map { |entry| @text_builder.entry_text(entry, EMBEDDING_VARIANT) }
      usage = PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(input_units: texts.sum { |text| [text.bytesize, 1].max }, output_units: 0).to_h
      retries = settings.fetch("max_retries") + 1
      {
        provider: context.fetch(:embedding_provider),
        adapter: settings.fetch("adapter"),
        model: settings.fetch("model"),
        variant: EMBEDDING_VARIANT,
        requests: 2,
        maximum_requests_with_retries: 2 * retries,
        maximum_input_units_from_utf8_bytes: usage.fetch(:input_units),
        maximum_cost_with_one_retry_jpy: (usage.fetch(:estimated_cost_jpy) * retries).round(4),
        external_api: settings.fetch("adapter") != "fixture"
      }
    end

    def maximum_evaluation_usage(settings, context)
      candidate_payloads = context.fetch(:approved_lines).map do |line|
        { "line" => line.slice("id", "text"), "similarity" => -1.0 }
      end.sort_by { |item| -JSON.generate(item).bytesize }.first(context.fetch(:candidate_limit))
      total_input = context.fetch(:entries).sum do |entry|
        input = {
          "meaning" => entry.fetch("expected").slice("themes", "structure", "abstraction"),
          "candidates" => candidate_payloads
        }
        @prompts.fetch(:line_evaluation).bytesize +
          JSON.generate(@schemas.fetch(:line_evaluation)).bytesize +
          JSON.generate(input).bytesize +
          PROVIDER_PROMPT_OVERHEAD_RESERVE
      end * context.fetch(:repetitions)
      total_output = settings.fetch("max_output_tokens") * context.fetch(:entries).length * context.fetch(:repetitions)
      retries = settings.fetch("max_retries") + 1
      PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(input_units: total_input * retries, output_units: total_output * retries).to_h
    end

    def ensure_external_api_allowed!(context)
      external = context.fetch(:embedding_settings).fetch("adapter") != "fixture" ||
                 context.fetch(:providers).any? do |name|
                   @configuration.line_evaluation_provider(name).fetch("adapter") != "fixture"
                 end
      raise ExternalApiDisabledError.new(:line_evaluation) if external && !@allow_external_api
    end

    def enforce_budget!(preflight)
      estimate = preflight.fetch(:maximum_cost_with_one_retry_jpy)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: estimate, limit_jpy: limit) if estimate > limit
    end

    def enforce_runtime_budget!(cost)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: cost.round(4), limit_jpy: limit) if cost > limit
    end

    def validate_embedding_dimensions!(vectors, settings)
      dimensions = vectors.map(&:length).uniq
      return if dimensions == [settings.fetch("dimensions")]

      raise ProviderContractError.new(
        "Embedding dimensions do not match configuration",
        operation: :embedding,
        details: { expected: settings.fetch("dimensions"), actual: dimensions }
      )
    end

    def vector_values(invocation)
      invocation.value.fetch("vectors").map { |item| item.fetch("values") }
    end

    def add_usage(*usages)
      sum_usage(usages.map { |usage| symbolize(usage) })
    end

    def sum_usage(usages)
      usages.each_with_object(Usage.zero.to_h) do |usage, total|
        %i[input_units output_units cached_input_units].each { |key| total[key] += usage.fetch(key, 0).to_i }
        %i[estimated_cost_usd estimated_cost_jpy].each { |key| total[key] += usage.fetch(key, 0).to_f }
      end.tap do |total|
        total[:estimated_cost_usd] = total[:estimated_cost_usd].round(8)
        total[:estimated_cost_jpy] = total[:estimated_cost_jpy].round(4)
      end
    end

    def total_cost(records)
      records.sum { |record| symbolize(record.fetch(:usage)).fetch(:estimated_cost_jpy) }
    end

    def symbolize(value)
      value.transform_keys(&:to_sym)
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

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "line_evaluation_#{timestamp}_#{SecureRandom.hex(2)}")
    end
  end
end
