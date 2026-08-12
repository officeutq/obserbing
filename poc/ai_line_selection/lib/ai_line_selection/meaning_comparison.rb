# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class MeaningComparison
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
    end

    def call(providers:, repetitions:, entry_ids: nil, output_dir: nil)
      raise ExternalApiDisabledError.new(:meaning) unless @allow_external_api

      providers = validate_providers(providers)
      repetitions = validate_repetitions(repetitions)
      entries = selected_entries(entry_ids)
      validate_request_limit!(providers, repetitions, entries)
      preflight_budget!(providers, repetitions, entries)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      telemetry = Telemetry.new(
        correlation_id: SecureRandom.uuid,
        path: File.join(@output_dir, "telemetry.jsonl")
      )
      client = OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: telemetry,
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
      records = []
      total = providers.length * entries.length * repetitions
      completed = 0

      providers.each do |provider_name|
        settings = @configuration.meaning_provider(provider_name)
        entries.each do |entry|
          repetitions.times do |index|
            @progress.call("meaning #{provider_name} #{entry.fetch("id")} #{index + 1}/#{repetitions}")
            record = execute(client, provider_name, settings, entry, index + 1)
            records << record
            append_jsonl("provider_outputs.jsonl", record)
            completed += 1
            validate_runtime_safety!(records, record, settings)
          end
        end
      end

      write_artifacts(records, providers, repetitions, entries)
      summary = build_summary(records, providers, repetitions, entries, completed: completed, expected: total)
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_failure(e, client&.last_attempts, completed: completed || 0, expected: total || 0) if @output_dir
      raise
    end

    private

    def execute(client, provider_name, settings, entry, repetition)
      invocation = client.call(
        :meaning,
        { "entry_text" => entry.fetch("body") },
        settings: settings
      )
      {
        entry_id: entry.fetch("id"),
        repetition: repetition,
        provider: provider_name,
        model: invocation.metadata.fetch(:model),
        request_id: invocation.metadata.fetch(:request_id),
        status: "success",
        meaning: invocation.value,
        duration_ms: invocation.metadata.fetch(:duration_ms),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        retry_count: invocation.metadata.fetch(:retry_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        attempts: invocation.metadata.fetch(:attempts),
        usage: invocation.metadata.fetch(:usage)
      }
    rescue AiLineSelection::Error => e
      append_jsonl(
        "failures.jsonl",
        {
          entry_id: entry.fetch("id"),
          repetition: repetition,
          provider: provider_name,
          model: settings.fetch("model"),
          status: "error",
          error_code: e.code,
          attempts: client.last_attempts
        }
      )
      raise
    end

    def validate_providers(providers)
      names = Array(providers).map(&:to_s).reject(&:empty?).uniq
      raise ConfigurationError.new("At least one Meaning provider is required") if names.empty?

      unknown = names - @configuration.meaning_provider_names
      raise ConfigurationError.new("Unknown Meaning providers", details: { providers: unknown }) unless unknown.empty?
      names
    end

    def validate_repetitions(repetitions)
      value = Integer(repetitions)
      maximum = @configuration.external_api.fetch("maximum_repetitions")
      return value if value.between?(1, maximum)

      raise ConfigurationError.new(
        "Meaning comparison repetitions are outside the allowed range",
        details: { repetitions: value, maximum: maximum }
      )
    end

    def selected_entries(entry_ids)
      return @data.entries if entry_ids.nil? || entry_ids.empty?

      Array(entry_ids).map { |id| @data.entry(id) }
    end

    def validate_request_limit!(providers, repetitions, entries)
      requested = providers.length * repetitions * entries.length
      maximum = @configuration.external_api.fetch("maximum_comparison_requests")
      return if requested <= maximum

      raise ConfigurationError.new(
        "Meaning comparison exceeds the configured request limit",
        details: { requested: requested, maximum: maximum }
      )
    end

    def preflight_budget!(providers, repetitions, entries)
      estimate = providers.sum do |name|
        settings = @configuration.meaning_provider(name)
        entries.sum do |entry|
          maximum_request_cost(settings, entry) * (settings.fetch("max_retries") + 1) * repetitions
        end
      end
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      return if estimate <= limit

      raise BudgetExceededError.new(estimated_cost_jpy: estimate.round(4), limit_jpy: limit)
    end

    def maximum_request_cost(settings, entry)
      input_units = ((@prompts.fetch(:meaning).length + entry.fetch("body").length) / 4.0).ceil
      PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(
        input_units: input_units,
        output_units: settings.fetch("max_output_tokens")
      ).estimated_cost_jpy
    end

    def validate_runtime_safety!(records, record, settings)
      usage = symbolize_keys(record.fetch(:usage))
      if usage.fetch(:output_units) > settings.fetch("max_output_tokens")
        raise CostAnomalyError.new(
          record.fetch(:provider),
          observed_cost_jpy: usage.fetch(:estimated_cost_jpy),
          expected_max_cost_jpy: maximum_request_cost(settings, @data.entry(record.fetch(:entry_id)))
        )
      end

      maximum = maximum_request_cost(settings, @data.entry(record.fetch(:entry_id))) * record.fetch(:attempt_count) * 1.25
      if usage.fetch(:estimated_cost_jpy) > maximum
        raise CostAnomalyError.new(
          record.fetch(:provider),
          observed_cost_jpy: usage.fetch(:estimated_cost_jpy),
          expected_max_cost_jpy: maximum.round(4)
        )
      end

      total = records.sum { |item| symbolize_keys(item.fetch(:usage)).fetch(:estimated_cost_jpy) }
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: total.round(4), limit_jpy: limit) if total > limit
    end

    def write_artifacts(records, providers, repetitions, entries)
      blinded = records.shuffle(random: Random.new(@configuration.random_seed)).each_with_index.map do |record, index|
        [format("B%04d", index + 1), record]
      end
      write_human_evaluation(blinded, entries)
      write_blind_mapping(blinded)
      write_manifest(providers, repetitions, entries)
    end

    def write_human_evaluation(blinded, entries)
      entries_by_id = entries.to_h { |entry| [entry.fetch("id"), entry] }
      path = File.join(@output_dir, "human_evaluation.csv")
      CSV.open(path, "w:UTF-8", write_headers: true, headers: [
        "blind_id", "entry_id", "entry_body", "themes", "structure", "abstraction",
        "usability_1_3", "contains_diagnosis", "unjustified_fixed_emotion_or_personality",
        "unnecessary_proper_noun", "notes"
      ]) do |csv|
        blinded.each do |blind_id, record|
          meaning = record.fetch(:meaning)
          csv << [
            blind_id,
            record.fetch(:entry_id),
            entries_by_id.fetch(record.fetch(:entry_id)).fetch("body"),
            JSON.generate(meaning.fetch("themes")),
            meaning.fetch("structure"),
            meaning.fetch("abstraction"),
            nil, nil, nil, nil, nil
          ]
        end
      end
    end

    def write_blind_mapping(blinded)
      path = File.join(@output_dir, "blind_mapping.csv")
      CSV.open(
        path,
        "w:UTF-8",
        write_headers: true,
        headers: %w[blind_id entry_id repetition provider model request_id]
      ) do |csv|
        blinded.each do |blind_id, record|
          csv << [
            blind_id,
            record.fetch(:entry_id),
            record.fetch(:repetition),
            record.fetch(:provider),
            record.fetch(:model),
            record.fetch(:request_id)
          ]
        end
      end
    end

    def write_manifest(providers, repetitions, entries)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601,
          operation: "meaning",
          providers: providers.to_h do |name|
            settings = @configuration.meaning_provider(name)
            [
              name,
              settings.slice(
                "provider", "model", "api", "reasoning_effort", "max_output_tokens",
                "timeout_seconds", "max_retries", "pricing"
              )
            ]
          end,
          repetitions: repetitions,
          entry_count: entries.length,
          entry_ids: entries.map { |entry| entry.fetch("id") },
          prompt_sha256: Digest::SHA256.hexdigest(@prompts.fetch(:meaning)),
          schema_sha256: Digest::SHA256.hexdigest(JSON.generate(@schemas.fetch(:meaning))),
          external_api_flag_required: true,
          tools_enabled: false
        }
      )
    end

    def build_summary(records, providers, repetitions, entries, completed:, expected:)
      {
        operation: "meaning",
        completed_executions: completed,
        expected_executions: expected,
        repetitions: repetitions,
        entry_count: entries.length,
        human_evaluation_pending: true,
        providers: providers.to_h do |name|
          provider_records = records.select { |record| record.fetch(:provider) == name }
          [name, provider_summary(provider_records, entries, repetitions)]
        end
      }
    end

    def provider_summary(records, entries, repetitions)
      executions = records.length
      attempts = records.flat_map { |record| record.fetch(:attempts) }
      usage = records.map { |record| symbolize_keys(record.fetch(:usage)) }
      durations = records.map { |record| record.fetch(:duration_ms).to_f }
      stable_entries = entries.count do |entry|
        values = records.select { |record| record.fetch(:entry_id) == entry.fetch("id") }
                        .map { |record| canonical_json(record.fetch(:meaning)) }
        values.length == repetitions && values.uniq.length == 1
      end
      field_stability = meaning_field_stability(records, entries, repetitions)
      {
        model: records.first&.fetch(:model, nil),
        executions: executions,
        requests_including_retries: records.sum { |record| record.fetch(:attempt_count) },
        first_attempt_schema_success_rate: ratio(records.count { |record| record.fetch(:first_attempt_success) }, executions),
        success_after_retry_count: records.count { |record| record.fetch(:retry_count).positive? },
        failure_count: 0,
        missing_required_count: attempts.sum { |attempt| attempt.fetch(:missing_required_count, 0) },
        latency_ms: {
          p50: percentile(durations, 0.50),
          p95: percentile(durations, 0.95),
          max: durations.max&.round(2)
        },
        tokens: {
          input: usage.sum { |item| item.fetch(:input_units) },
          output: usage.sum { |item| item.fetch(:output_units) },
          cached_input: usage.sum { |item| item.fetch(:cached_input_units) }
        },
        estimated_cost_usd: usage.sum { |item| item.fetch(:estimated_cost_usd) }.round(8),
        estimated_cost_jpy: usage.sum { |item| item.fetch(:estimated_cost_jpy) }.round(4),
        estimated_cost_per_post_usd: average(usage.sum { |item| item.fetch(:estimated_cost_usd) }, executions, 8),
        estimated_cost_per_post_jpy: average(usage.sum { |item| item.fetch(:estimated_cost_jpy) }, executions, 4),
        exact_stability: repetitions > 1 ? { stable_entries: stable_entries, total_entries: entries.length, rate: ratio(stable_entries, entries.length) } : nil,
        field_stability: field_stability
      }
    end

    def meaning_field_stability(records, entries, repetitions)
      return nil unless repetitions > 1

      groups = entries.map do |entry|
        records.select { |record| record.fetch(:entry_id) == entry.fetch("id") }
      end.select { |group| group.length == repetitions }
      exact_counts = %w[themes structure abstraction].to_h do |field|
        [field, groups.count { |group| group.map { |record| record.fetch(:meaning).fetch(field) }.uniq.length == 1 }]
      end
      theme_similarities = groups.flat_map do |group|
        group.map { |record| record.fetch(:meaning).fetch("themes").uniq }.combination(2).map do |left, right|
          union = left | right
          union.empty? ? 1.0 : (left & right).length.to_f / union.length
        end
      end

      {
        exact_rate_by_field: exact_counts.transform_values { |count| ratio(count, groups.length) },
        themes_pairwise_jaccard_average: average(theme_similarities.sum, theme_similarities.length, 4)
      }
    end

    def write_failure(error, attempts, completed:, expected:)
      write_json(
        "stopped.json",
        {
          stopped_at: @now.call.iso8601,
          completed_executions: completed,
          expected_executions: expected,
          error_code: error.code,
          attempts: attempts || []
        }
      )
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "meaning_#{timestamp}_#{SecureRandom.hex(2)}")
    end

    def percentile(values, fraction)
      return nil if values.empty?

      ordered = values.sort
      index = [(ordered.length * fraction).ceil - 1, 0].max
      ordered.fetch(index).round(2)
    end

    def ratio(numerator, denominator)
      return nil if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count, precision)
      return nil if count.zero?

      (total.to_f / count).round(precision)
    end

    def canonical_json(value)
      JSON.generate(value.sort.to_h)
    end

    def symbolize_keys(value)
      value.transform_keys(&:to_sym)
    end
  end
end
