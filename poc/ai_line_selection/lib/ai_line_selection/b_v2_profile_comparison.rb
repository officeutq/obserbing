# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class Bv2ProfileComparison
    ENTRY_IDS = %w[E001 E003 E008 E023 E032 E035].freeze
    LINE_IDS = %w[L021 L083 L102 L118].freeze
    ITEM_IDS = (ENTRY_IDS + LINE_IDS).freeze
    REPETITIONS = 3
    MAX_TOTAL_TOKENS = 50_000
    MAX_COST_JPY = 500.0
    MAX_OUTPUT_TOKENS = 192
    VERSIONS = {
      "b-v2-profile-single-v1" => {
        prompt_file: "b_v2_profile_single_v1.md",
        schema_file: "b_v2_profile_single_v1.json"
      },
      "b-v2-profile-primary-secondary-v1" => {
        prompt_file: "b_v2_profile_primary_secondary_v1.md",
        schema_file: "b_v2_profile_primary_secondary_v1.json"
      }
    }.freeze

    def initialize(configuration:, allow_external_api: false, environment: ENV, transport: nil,
                   progress: nil, now: -> { Time.now.utc })
      @configuration = configuration
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @progress = progress || ->(_message) {}
      @now = now
      @data = DataLoader.new(configuration)
    end

    def plan(provider: "openai", versions: VERSIONS.keys, repetitions: REPETITIONS, item_ids: ITEM_IDS)
      context = build_context(provider, versions, repetitions, item_ids)
      normal_requests = context.fetch(:versions).length * context.fetch(:items).length * context.fetch(:repetitions)
      retries = context.fetch(:settings).fetch("max_retries").to_i
      {
        operation: "b_v2_profile_smoke_v1",
        network_call_performed: false,
        provider: safe_settings(context.fetch(:settings)),
        versions: context.fetch(:versions),
        item_ids: context.fetch(:items).map { |item| item.fetch("id") },
        item_count: context.fetch(:items).length,
        repetitions: context.fetch(:repetitions),
        normal_requests: normal_requests,
        maximum_requests_with_retries: normal_requests * (retries + 1),
        maximum_total_tokens: MAX_TOTAL_TOKENS,
        maximum_cost_jpy: MAX_COST_JPY,
        conservative_token_cap_cost_jpy: token_cap_cost(context.fetch(:settings)),
        synthetic_data_only: true,
        external_api_flag_required: context.fetch(:settings).fetch("adapter") != "fixture"
      }
    end

    def call(provider: "openai", versions: VERSIONS.keys, repetitions: REPETITIONS,
             item_ids: ITEM_IDS, output_dir: nil)
      context = build_context(provider, versions, repetitions, item_ids)
      if context.fetch(:settings).fetch("adapter") != "fixture" && !@allow_external_api
        raise ExternalApiDisabledError.new(:abstraction)
      end
      planned = plan(provider: provider, versions: versions, repetitions: repetitions, item_ids: item_ids)
      raise BudgetExceededError.new(estimated_cost_jpy: planned.fetch(:conservative_token_cap_cost_jpy), limit_jpy: MAX_COST_JPY) if planned.fetch(:conservative_token_cap_cost_jpy) > MAX_COST_JPY

      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      records = []
      context.fetch(:versions).each do |version|
        client = client_for(version)
        context.fetch(:items).each do |item|
          context.fetch(:repetitions).times do |index|
            @progress.call("profile #{version} #{item.fetch('id')} #{index + 1}/#{context.fetch(:repetitions)}")
            invocation = client.call(
              :abstraction,
              { "text" => item.fetch("text") },
              fixture_context: item,
              settings: settings_for(context.fetch(:settings), version)
            )
            record = normalized_record(version, item, index + 1, invocation)
            validate_profile!(record)
            records << record
            enforce_actual_limits!(records)
            append_jsonl("normalized_outputs.jsonl", record)
          end
        end
      end
      summary = build_summary(context, records)
      write_json("manifest.json", manifest(context))
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json("stopped.json", { stopped_at: @now.call.iso8601, error_code: e.code }) if @output_dir
      raise
    end

    private

    def build_context(provider, versions, repetitions, item_ids)
      selected_versions = Array(versions).map(&:to_s)
      unknown = selected_versions - VERSIONS.keys
      raise ConfigurationError.new("Unknown B-v2 profile version", details: { versions: unknown }) unless unknown.empty?
      raise ConfigurationError.new("One or two B-v2 profile versions are required") unless selected_versions.length.between?(1, 2)
      count = Integer(repetitions)
      raise ConfigurationError.new("B-v2 profile smoke requires 1..3 repetitions") unless count.between?(1, REPETITIONS)

      available = all_items.to_h { |item| [item.fetch("id"), item] }
      selected_items = Array(item_ids).map do |id|
        available.fetch(id.to_s) { raise DataError.new("Unknown profile item", details: { id: id.to_s }) }
      end
      {
        provider: provider.to_s,
        settings: @configuration.meaning_provider(provider.to_s),
        versions: selected_versions,
        repetitions: count,
        items: selected_items
      }
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("B-v2 profile repetitions must be an integer")
    end

    def all_items
      @all_items ||= begin
        entries = @data.entries.filter_map do |entry|
          next unless ENTRY_IDS.include?(entry.fetch("id"))
          { "id" => entry.fetch("id"), "source_type" => "entry", "text" => entry.fetch("body") }
        end
        lines = @data.lines.filter_map do |line|
          next unless LINE_IDS.include?(line.fetch("id"))
          { "id" => line.fetch("id"), "source_type" => "line", "text" => line.fetch("text") }
        end
        (entries + lines).freeze
      end
    end

    def client_for(version)
      files = VERSIONS.fetch(version)
      schemas = SchemaRegistry.new(root_dir: @configuration.root_dir, files: { abstraction: files.fetch(:schema_file) })
      prompts = PromptRegistry.new(root_dir: @configuration.root_dir, files: { abstraction: files.fetch(:prompt_file) })
      OperationClient.new(
        configuration: @configuration,
        schemas: schemas,
        prompts: prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: nil),
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
    end

    def settings_for(settings, version)
      settings.merge(
        "max_output_tokens" => MAX_OUTPUT_TOKENS,
        "prompt_version" => version,
        "schema_version" => version
      )
    end

    def normalized_record(version, item, repetition, invocation)
      value = invocation.value
      domain = value.fetch("domain")
      normalized_domain = if domain.is_a?(String)
                            { primary: domain, secondary: [] }
                          else
                            { primary: domain.fetch("primary"), secondary: domain.fetch("secondary") }
                          end
      {
        version: version,
        item_id: item.fetch("id"),
        source_type: item.fetch("source_type"),
        repetition: repetition,
        abstraction: value.fetch("abstraction"),
        domain: normalized_domain,
        model: invocation.metadata.fetch(:model),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        retry_count: invocation.metadata.fetch(:retry_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        duration_ms: invocation.metadata.fetch(:duration_ms),
        usage: invocation.metadata.fetch(:usage)
      }
    end

    def validate_profile!(record)
      domain = record.fetch(:domain)
      if domain.fetch(:secondary).include?(domain.fetch(:primary))
        raise SchemaValidationError.new(:abstraction, ["$.domain.secondary: must not repeat primary"])
      end
    end

    def enforce_actual_limits!(records)
      tokens = records.sum do |record|
        usage = symbolize(record.fetch(:usage))
        usage.fetch(:input_units) + usage.fetch(:output_units)
      end
      cost = records.sum { |record| symbolize(record.fetch(:usage)).fetch(:estimated_cost_jpy) }
      if tokens > MAX_TOTAL_TOKENS
        raise ConfigurationError.new("B-v2 profile smoke exceeded token cap", details: { actual_tokens: tokens, maximum: MAX_TOTAL_TOKENS })
      end
      raise BudgetExceededError.new(estimated_cost_jpy: cost.round(4), limit_jpy: MAX_COST_JPY) if cost > MAX_COST_JPY
    end

    def build_summary(context, records)
      per_version = context.fetch(:versions).to_h do |version|
        selected = records.select { |record| record.fetch(:version) == version }
        item_groups = selected.group_by { |record| record.fetch(:item_id) }
        stable_abstraction = item_groups.count { |_id, rows| rows.map { |row| row.fetch(:abstraction) }.uniq.one? }
        stable_primary = item_groups.count { |_id, rows| rows.map { |row| row.dig(:domain, :primary) }.uniq.one? }
        swaps = item_groups.count do |_id, rows|
          rows.combination(2).any? do |left, right|
            left_primary = left.dig(:domain, :primary)
            right_primary = right.dig(:domain, :primary)
            left.dig(:domain, :secondary).include?(right_primary) || right.dig(:domain, :secondary).include?(left_primary)
          end
        end
        unknown_other = selected.count { |row| ([row.dig(:domain, :primary)] + row.dig(:domain, :secondary)).any? { |value| %w[unknown other].include?(value) } }
        [version, {
          executions: selected.length,
          first_attempt_schema_success_rate: ratio(selected.count { |row| row.fetch(:first_attempt_success) }, selected.length),
          abstraction_exact_stability_rate: ratio(stable_abstraction, item_groups.length),
          domain_primary_exact_stability_rate: ratio(stable_primary, item_groups.length),
          primary_secondary_swap_item_count: swaps,
          unknown_or_other_output_rate: ratio(unknown_other, selected.length),
          latency_ms: latency(selected),
          usage: aggregate_usage(selected)
        }]
      end
      {
        operation: "b_v2_profile_smoke_v1",
        completed: true,
        item_count: context.fetch(:items).length,
        repetitions: context.fetch(:repetitions),
        versions: per_version,
        total_executions: records.length,
        total_tokens: records.sum { |record| symbolize(record.fetch(:usage)).fetch(:input_units) + symbolize(record.fetch(:usage)).fetch(:output_units) },
        total_estimated_cost_jpy: records.sum { |record| symbolize(record.fetch(:usage)).fetch(:estimated_cost_jpy) }.round(4),
        manual_quality_review_pending: true,
        external_api_limits: { maximum_total_tokens: MAX_TOTAL_TOKENS, maximum_cost_jpy: MAX_COST_JPY }
      }
    end

    def latency(records)
      values = records.map { |record| record.fetch(:duration_ms).to_f }.sort
      { p50: percentile(values, 0.50), p95: percentile(values, 0.95), maximum: values.max&.round(2) }
    end

    def aggregate_usage(records)
      items = records.map { |record| symbolize(record.fetch(:usage)) }
      {
        input_units: items.sum { |item| item.fetch(:input_units) },
        output_units: items.sum { |item| item.fetch(:output_units) },
        cached_input_units: items.sum { |item| item.fetch(:cached_input_units) },
        estimated_cost_jpy: items.sum { |item| item.fetch(:estimated_cost_jpy) }.round(4)
      }
    end

    def token_cap_cost(settings)
      pricing = settings.fetch("pricing")
      maximum_per_million = [pricing.fetch("input_per_million_usd"), pricing.fetch("output_per_million_usd")].map(&:to_f).max
      (MAX_TOTAL_TOKENS * maximum_per_million / 1_000_000.0 * @configuration.external_api.fetch("usd_to_jpy").to_f).round(4)
    end

    def manifest(context)
      {
        created_at: @now.call.iso8601,
        operation: "b_v2_profile_smoke_v1",
        source: "synthetic",
        provider: safe_settings(context.fetch(:settings)),
        versions: context.fetch(:versions).to_h do |version|
          files = VERSIONS.fetch(version)
          prompt_path = File.join(@configuration.root_dir, "prompts", files.fetch(:prompt_file))
          schema_path = File.join(@configuration.root_dir, "schemas", files.fetch(:schema_file))
          [version, { prompt_sha256: Digest::SHA256.file(prompt_path).hexdigest, schema_sha256: Digest::SHA256.file(schema_path).hexdigest }]
        end,
        item_ids: context.fetch(:items).map { |item| item.fetch("id") },
        repetitions: context.fetch(:repetitions),
        entry_data_sha256: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
        line_data_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
        source_text_saved_in_output: false,
        provider_raw_response_saved: false,
        api_key_saved: false
      }
    end

    def safe_settings(settings)
      settings.slice("adapter", "provider", "model", "api", "reasoning_effort", "timeout_seconds", "max_retries", "pricing")
    end

    def percentile(values, fraction)
      return nil if values.empty?
      values.fetch([(values.length * fraction).ceil - 1, 0].max).round(2)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?
      (numerator.to_f / denominator).round(4)
    end

    def symbolize(value)
      value.to_h.transform_keys(&:to_sym)
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      File.join(@configuration.path(:results), "b_v2_profile_#{@now.call.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(2)}")
    end
  end
end
