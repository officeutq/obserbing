# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class Bv2IntegratedComparison
    VERSION = "b-v2-integrated-live-v1"
    PROFILE_VERSION = "b-v2-profile-primary-secondary-v1"
    EMBEDDING_VERSION = "b-v2-openai-small-dual-cosine-v1"
    SELECTOR_STRATEGY = "uniform"
    REPETITIONS = 3
    TOP_N = 20
    A_MIN = 0.45
    S_MAX = 0.55
    MAX_OUTPUT_TOKENS = 192
    ISSUE_BUDGET_JPY = 1_500.0
    EPIC_BUDGET_JPY = 2_000.0
    EPIC_SPEND_BEFORE_JPY = 12.1248
    MAX_TOTAL_TOKENS = 500_000

    def initialize(configuration:, allow_external_api: false, environment: ENV, transport: nil,
                   progress: nil, now: -> { Time.now.utc })
      @configuration = configuration
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @progress = progress || ->(_message) {}
      @now = now
      @data = DataLoader.new(configuration)
      @guard = Bv2PolicyGuard.new(configuration: configuration)
      @schemas = SchemaRegistry.new(
        root_dir: configuration.root_dir,
        files: {
          safety: "safety_additional_v3.json",
          abstraction: "b_v2_profile_primary_secondary_v1.json"
        }
      )
      @prompts = PromptRegistry.new(
        root_dir: configuration.root_dir,
        files: {
          safety: "safety_additional_v3.md",
          abstraction: "b_v2_profile_primary_secondary_v1.md"
        }
      )
    end

    def plan
      entries = @data.entries.length
      lines = approved_lines.length
      outcome_slots = entries * REPETITIONS
      normal_requests = lines + 1 + (outcome_slots * 3)
      {
        operation: VERSION,
        network_call_performed: false,
        line_count: lines,
        entry_count: entries,
        repetitions: REPETITIONS,
        outcome_slots: outcome_slots,
        profile: safe_settings(profile_settings),
        safety: safe_settings(safety_settings),
        embedding: safe_settings(embedding_settings),
        line_precompute_requests: lines + 1,
        post_requests: outcome_slots * 3,
        normal_requests: normal_requests,
        maximum_requests_with_retries: normal_requests * 2,
        maximum_total_tokens: MAX_TOTAL_TOKENS,
        conservative_token_cap_cost_jpy: 900.0,
        issue_budget_jpy: ISSUE_BUDGET_JPY,
        epic_spend_before_jpy: EPIC_SPEND_BEFORE_JPY,
        epic_budget_jpy: EPIC_BUDGET_JPY,
        within_issue_budget: 900.0 <= ISSUE_BUDGET_JPY,
        within_epic_budget: EPIC_SPEND_BEFORE_JPY + 900.0 <= EPIC_BUDGET_JPY,
        top_n: TOP_N,
        a_min: A_MIN,
        s_max: S_MAX,
        selector: SELECTOR_STRATEGY,
        realtime_line_evaluation_llm_calls: 0,
        external_api_flag_required: true,
        synthetic_data_only: true
      }
    end

    def call(output_dir:, resume: false, repair_safety_overblocks: false)
      raise ExternalApiDisabledError.new(:integrated) unless @allow_external_api
      planned = plan
      unless planned.fetch(:within_issue_budget) && planned.fetch(:within_epic_budget)
        raise BudgetExceededError.new(estimated_cost_jpy: planned.fetch(:conservative_token_cap_cost_jpy), limit_jpy: ISSUE_BUDGET_JPY)
      end

      @output_dir = File.expand_path(output_dir)
      if Dir.exist?(@output_dir) && !resume && !Dir.empty?(@output_dir)
        raise ConfigurationError.new("B-v2 output directory is not empty; use resume")
      end
      FileUtils.mkdir_p(@output_dir)
      client = operation_client
      line_profiles = load_jsonl("line_profiles.jsonl")
      precompute_line_profiles(client, line_profiles)
      line_index = load_or_build_line_index(client, line_profiles)
      records = load_jsonl("provider_outputs.jsonl")
      records, discarded_records = prepare_safety_repair(records, repair_safety_overblocks)
      run_outcomes(client, line_index, records, discarded_records)
      summary = build_summary(line_profiles, line_index, records, discarded_records)
      write_json("manifest.json", manifest(planned, repair_safety_overblocks, discarded_records))
      write_json("summary.json", summary)
      summary.merge(results_directory: @output_dir)
    rescue AiLineSelection::Error => e
      write_json("stopped.json", { stopped_at: @now.call.iso8601, error_code: e.code, details: e.details }) if @output_dir
      raise
    end

    private

    def operation_client
      OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@output_dir, "telemetry.jsonl")),
        allow_external_api: true,
        environment: @environment,
        transport: @transport
      )
    end

    def precompute_line_profiles(client, records)
      completed = records.to_h { |record| [record.fetch("line_id"), record] }
      approved_lines.each_with_index do |line, index|
        next if completed.key?(line.fetch("id"))
        @progress.call("line profile #{index + 1}/#{approved_lines.length} #{line.fetch('id')}")
        invocation = client.call(:abstraction, { "text" => line.fetch("text") }, settings: profile_settings)
        record = {
          line_id: line.fetch("id"),
          source_text_sha256: Digest::SHA256.hexdigest(line.fetch("text")),
          profile_version: PROFILE_VERSION,
          abstraction: invocation.value.fetch("abstraction"),
          domain: invocation.value.fetch("domain"),
          phase: phase_metadata(invocation)
        }
        validate_domain!(record.fetch(:domain))
        append_jsonl("line_profiles.jsonl", record)
        records << stringify(record)
        enforce_actual_limits!(records, [], nil)
      end
    end

    def load_or_build_line_index(client, line_profiles)
      path = artifact_path("line_index.json")
      return JSON.parse(File.read(path, encoding: "UTF-8")) if File.exist?(path)

      @progress.call("line dual embedding 1/1")
      by_id = line_profiles.to_h { |record| [record.fetch("line_id"), record] }
      texts = approved_lines.map { |line| by_id.fetch(line.fetch("id")).fetch("abstraction") } +
              approved_lines.map { |line| line.fetch("text") }
      invocation = client.call(:embedding, { "texts" => texts }, settings: embedding_settings)
      vectors = invocation.value.fetch("vectors").map { |item| item.fetch("values") }
      count = approved_lines.length
      document = {
        "line_ids" => approved_lines.map { |line| line.fetch("id") },
        "abstraction_vectors" => vectors.first(count),
        "surface_vectors" => vectors.drop(count),
        "phase" => stringify(phase_metadata(invocation))
      }
      write_json("line_index.json", document)
      enforce_actual_limits!(line_profiles, [], document.fetch("phase"))
      document
    end

    def run_outcomes(client, line_index, records, discarded_records)
      completed = records.to_h { |record| [[record.fetch("entry_id"), record.fetch("repetition")], record] }
      @data.entries.each_with_index do |entry, entry_index|
        REPETITIONS.times do |offset|
          repetition = offset + 1
          next if completed.key?([entry.fetch("id"), repetition])
          @progress.call("outcome #{entry_index * REPETITIONS + repetition}/#{@data.entries.length * REPETITIONS} #{entry.fetch('id')} R#{repetition}")
          started = monotonic_time
          safety = client.call(:safety, { "entry_text" => entry.fetch("body") }, settings: safety_settings)
          record = if safety.value.fetch("classification") == "normal"
                     build_normal_outcome(client, line_index, entry, repetition, safety, started)
                   else
                     build_safety_outcome(entry, repetition, safety, started)
                   end
          append_jsonl("provider_outputs.jsonl", record)
          records << stringify(record)
          enforce_actual_limits!(load_jsonl("line_profiles.jsonl"), records, line_index.fetch("phase"), discarded_records)
        end
      end
    end

    def prepare_safety_repair(records, enabled)
      archived = load_jsonl("invalid_safety_outputs.jsonl")
      return [records, archived] unless enabled

      invalid = records.select do |record|
        record.fetch("status") == "safety_stop" && record.fetch("safety_classification") == "indeterminate"
      end
      unless invalid.empty?
        archived_by_slot = archived.to_h { |record| [[record.fetch("entry_id"), record.fetch("repetition")], record] }
        invalid.each { |record| archived_by_slot[[record.fetch("entry_id"), record.fetch("repetition")]] ||= record }
        archived = archived_by_slot.values.sort_by { |record| [record.fetch("entry_id"), record.fetch("repetition")] }
        write_jsonl("invalid_safety_outputs.jsonl", archived)
        invalid_slots = invalid.map { |record| [record.fetch("entry_id"), record.fetch("repetition")] }.to_h { |slot| [slot, true] }
        records = records.reject { |record| invalid_slots.key?([record.fetch("entry_id"), record.fetch("repetition")]) }
        write_jsonl("provider_outputs.jsonl", records)
      end
      [records, archived]
    end

    def build_normal_outcome(client, line_index, entry, repetition, safety, started)
      profile = client.call(:abstraction, { "text" => entry.fetch("body") }, settings: profile_settings)
      validate_domain!(profile.value.fetch("domain"))
      embedding = client.call(
        :embedding,
        { "texts" => [profile.value.fetch("abstraction"), entry.fetch("body")] },
        settings: embedding_settings
      )
      vectors = embedding.value.fetch("vectors").map { |item| item.fetch("values") }
      candidates, exclusions = eligible_candidates(entry, vectors, line_index)
      seed = Bv2Selector.seed(base_seed: @configuration.random_seed, entry_id: entry.fetch("id"), repetition: repetition)
      selector = Bv2Selector.new(strategy: SELECTOR_STRATEGY)
      selection = selector.select(candidates: candidates, seed: seed)
      repeated = selector.select(candidates: candidates, seed: seed)
      raise DataError.new("B-v2 selector was not reproducible") unless selection == repeated
      selected = candidates.find { |candidate| candidate.fetch("line_id") == selection.fetch(:line_id) }
      {
        entry_id: entry.fetch("id"),
        repetition: repetition,
        status: selection.fetch(:status),
        safety_classification: "normal",
        semantic_silence: selection.fetch(:status) == "silence",
        silence_reason: selection.fetch(:silence_reason),
        technical_error: false,
        profile_version: PROFILE_VERSION,
        abstraction: profile.value.fetch("abstraction"),
        domain: profile.value.fetch("domain"),
        top_n_count: TOP_N,
        a_min_eligible_count: exclusions.fetch(:a_min_pass),
        surface_exclusion_count: exclusions.fetch(:surface),
        policy_exclusion_count: exclusions.fetch(:policy),
        eligible_count: candidates.length,
        eligible_line_ids: candidates.map { |candidate| candidate.fetch("line_id") },
        selected_line_id: selection.fetch(:line_id),
        selected_abstraction_similarity: selected && selected.fetch("abstraction_similarity"),
        selected_surface_similarity: selected && selected.fetch("surface_similarity"),
        selector_version: Bv2Selector::VERSION,
        selector_strategy: SELECTOR_STRATEGY,
        seed: seed,
        selection_same_seed_reproduced: true,
        full_flow_duration_ms: elapsed_ms(started),
        request_count: 3,
        phases: {
          safety: phase_metadata(safety),
          profile: phase_metadata(profile),
          embedding: phase_metadata(embedding)
        }
      }
    end

    def build_safety_outcome(entry, repetition, safety, started)
      {
        entry_id: entry.fetch("id"), repetition: repetition, status: "safety_stop",
        safety_classification: safety.value.fetch("classification"), semantic_silence: false,
        silence_reason: "safety_#{safety.value.fetch('classification')}", technical_error: false,
        selected_line_id: nil, eligible_count: 0, full_flow_duration_ms: elapsed_ms(started),
        request_count: 1, phases: { safety: phase_metadata(safety) }
      }
    end

    def eligible_candidates(entry, entry_vectors, line_index)
      line_ids = line_index.fetch("line_ids")
      abstraction_vectors = line_index.fetch("abstraction_vectors")
      surface_vectors = line_index.fetch("surface_vectors")
      line_by_id = approved_lines.to_h { |line| [line.fetch("id"), line] }
      ranked = line_ids.each_with_index.map do |line_id, index|
        {
          "line_id" => line_id,
          "abstraction_similarity" => cosine(entry_vectors.fetch(0), abstraction_vectors.fetch(index)),
          "surface_similarity" => cosine(entry_vectors.fetch(1), surface_vectors.fetch(index))
        }
      end.sort_by { |candidate| [-candidate.fetch("abstraction_similarity"), candidate.fetch("line_id")] }.first(TOP_N)
      a_min_rows = ranked.select { |candidate| candidate.fetch("abstraction_similarity") >= A_MIN }
      surface_excluded = a_min_rows.select { |candidate| candidate.fetch("surface_similarity") > S_MAX }
      after_surface = a_min_rows - surface_excluded
      policy_excluded = []
      eligible = after_surface.filter_map do |candidate|
        line = line_by_id.fetch(candidate.fetch("line_id"))
        decision = @guard.evaluate(
          entry: entry, line: line, profile_version: PROFILE_VERSION,
          embedding_version: EMBEDDING_VERSION, history: [], line_claims: []
        )
        unless decision.fetch(:eligible)
          policy_excluded << candidate
          next
        end
        candidate.merge(
          "domain_primary" => line_domain(line),
          "line" => line
        )
      end
      [eligible, { a_min_pass: a_min_rows.length, surface: surface_excluded.length, policy: policy_excluded.length }]
    end

    def line_domain(line)
      Bv2SelectorComparison::DOMAIN_MAP.fetch(line.fetch("theme"), "other")
    end

    def build_summary(line_profiles, line_index, records, discarded_records)
      normal = records.select { |record| record.fetch("safety_classification") == "normal" }
      selected = normal.select { |record| record.fetch("status") == "line" }
      usages = all_usage(line_profiles, records, line_index.fetch("phase"), discarded_records)
      post_usages = records.flat_map { |record| record.fetch("phases").values.map { |phase| phase.fetch("usage") } }
      {
        operation: VERSION,
        completed: records.length == @data.entries.length * REPETITIONS,
        line_precompute: { profile_count: line_profiles.length, embedding_requests: 1 },
        execution: { entry_count: @data.entries.length, repetitions: REPETITIONS, outcome_slots: records.length },
        safety: {
          normal_count: normal.length,
          overblock_count: records.count { |record| record.fetch("safety_classification") != "normal" },
          discarded_invalid_prompt_attempt_count: discarded_records.length,
          discarded_attempts_preserved_in: discarded_records.empty? ? nil : "invalid_safety_outputs.jsonl"
        },
        profile: {
          version: PROFILE_VERSION,
          first_attempt_schema_success_rate: ratio(
            line_profiles.count { |row| row.dig("phase", "first_attempt_success") } +
              normal.count { |row| row.dig("phases", "profile", "first_attempt_success") },
            line_profiles.length + normal.length
          )
        },
        band_pass: {
          top_n: TOP_N, a_min: A_MIN, s_max: S_MAX,
          eligible_count: stats(normal.map { |record| record.fetch("eligible_count") }),
          a_min_pass_count_total: normal.sum { |record| record.fetch("a_min_eligible_count") },
          surface_exclusion_count_total: normal.sum { |record| record.fetch("surface_exclusion_count") },
          policy_exclusion_count_total: normal.sum { |record| record.fetch("policy_exclusion_count") }
        },
        selection: {
          selector_version: Bv2Selector::VERSION,
          strategy: SELECTOR_STRATEGY,
          selected_count: selected.length,
          semantic_silence_count: normal.count { |record| record.fetch("semantic_silence") },
          semantic_silence_rate: ratio(normal.count { |record| record.fetch("semantic_silence") }, normal.length),
          same_seed_reproducibility_rate: ratio(normal.count { |record| record.fetch("selection_same_seed_reproduced") }, normal.length),
          realtime_line_evaluation_llm_calls: 0,
          rule_violation_count: 0
        },
        technical_error_count: 0,
        latency_ms: stats(normal.map { |record| record.fetch("full_flow_duration_ms") }),
        api_and_cost: {
          requests_including_retries: usages.sum { |usage| usage.fetch("attempt_count") },
          input_units: usages.sum { |usage| usage.dig("usage", "input_units") },
          output_units: usages.sum { |usage| usage.dig("usage", "output_units") },
          total_tokens: usages.sum { |usage| usage.dig("usage", "input_units") + usage.dig("usage", "output_units") },
          issue_cost_jpy: usages.sum { |usage| usage.dig("usage", "estimated_cost_jpy") }.round(4),
          normal_post_cost_jpy: post_usages.sum { |usage| usage.fetch("estimated_cost_jpy") }.round(4),
          cost_per_post_jpy: (post_usages.sum { |usage| usage.fetch("estimated_cost_jpy") } / records.length).round(4),
          normal_external_requests_per_post: 3,
          epic_cumulative_jpy: (EPIC_SPEND_BEFORE_JPY + usages.sum { |usage| usage.dig("usage", "estimated_cost_jpy") }).round(4)
        },
        reflective_distance_evaluation_pending: true
      }
    end

    def all_usage(line_profiles, records, line_index_phase, discarded_records = [])
      line_profiles.map { |row| row.fetch("phase") } +
        [line_index_phase] +
        records.flat_map { |record| record.fetch("phases").values } +
        discarded_records.flat_map { |record| record.fetch("phases").values }
    end

    def enforce_actual_limits!(line_profiles, records, line_index_phase, discarded_records = [])
      phases = line_profiles.map { |row| row.fetch("phase") }
      phases << line_index_phase if line_index_phase
      phases.concat(records.flat_map { |record| record.fetch("phases").values })
      phases.concat(discarded_records.flat_map { |record| record.fetch("phases").values })
      tokens = phases.sum { |phase| phase.dig("usage", "input_units") + phase.dig("usage", "output_units") }
      cost = phases.sum { |phase| phase.dig("usage", "estimated_cost_jpy") }
      raise ConfigurationError.new("B-v2 integrated run exceeded token cap", details: { actual: tokens, maximum: MAX_TOTAL_TOKENS }) if tokens > MAX_TOTAL_TOKENS
      raise BudgetExceededError.new(estimated_cost_jpy: cost.round(4), limit_jpy: ISSUE_BUDGET_JPY) if cost > ISSUE_BUDGET_JPY
      if EPIC_SPEND_BEFORE_JPY + cost > EPIC_BUDGET_JPY
        raise BudgetExceededError.new(estimated_cost_jpy: (EPIC_SPEND_BEFORE_JPY + cost).round(4), limit_jpy: EPIC_BUDGET_JPY)
      end
    end

    def profile_settings
      @profile_settings ||= @configuration.meaning_provider("openai").merge(
        "max_output_tokens" => MAX_OUTPUT_TOKENS,
        "prompt_version" => PROFILE_VERSION,
        "schema_version" => PROFILE_VERSION
      )
    end

    def safety_settings
      @safety_settings ||= @configuration.safety_provider("openai").merge(
        "prompt_version" => "additional-v3",
        "schema_version" => "additional-v3"
      )
    end

    def embedding_settings
      @embedding_settings ||= @configuration.embedding_provider("openai-small")
    end

    def approved_lines
      @approved_lines ||= @data.lines.select { |line| line.fetch("status") == "approved" }
    end

    def validate_domain!(domain)
      primary = domain.fetch("primary")
      secondary = domain.fetch("secondary")
      raise SchemaValidationError.new(:abstraction, ["$.domain.secondary: must not repeat primary"]) if secondary.include?(primary)
    end

    def phase_metadata(invocation)
      {
        provider: invocation.metadata.fetch(:provider),
        model: invocation.metadata.fetch(:model),
        duration_ms: invocation.metadata.fetch(:duration_ms),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        retry_count: invocation.metadata.fetch(:retry_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        usage: invocation.metadata.fetch(:usage)
      }
    end

    def safe_settings(settings)
      settings.slice("adapter", "provider", "model", "api", "reasoning_effort", "dimensions", "max_output_tokens", "timeout_seconds", "max_retries", "pricing", "prompt_version", "schema_version")
    end

    def manifest(planned, repair_safety_overblocks, discarded_records)
      {
        created_at: @now.call.iso8601,
        operation: VERSION,
        source: "synthetic",
        preflight: planned,
        hashes: {
          entries: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
          lines: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
          design_criteria: Digest::SHA256.file(evaluation_path("b_v2_design_criteria_v2.yml")).hexdigest,
          profile_result: Digest::SHA256.file(evaluation_path("b_v2_profile_smoke_v1.yml")).hexdigest,
          band_pass: Digest::SHA256.file(evaluation_path("b_v2_band_pass_criteria_v1.yml")).hexdigest,
          policy: Digest::SHA256.file(evaluation_path("b_v2_guard_policy_v1.yml")).hexdigest,
          selector: Digest::SHA256.file(evaluation_path("b_v2_selector_criteria_v1.yml")).hexdigest
        },
        line_pool_changed: false,
        safety_boundary: "additional-v3",
        safety_repair_applied: repair_safety_overblocks,
        discarded_invalid_prompt_attempt_count: discarded_records.length,
        provider_raw_response_saved: false,
        api_key_saved: false,
        request_id_saved: false
      }
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def cosine(left, right)
      dot = left.zip(right).sum { |a, b| a * b }
      left_size = Math.sqrt(left.sum { |value| value * value })
      right_size = Math.sqrt(right.sum { |value| value * value })
      return 0.0 if left_size.zero? || right_size.zero?
      (dot / (left_size * right_size)).round(8)
    end

    def stats(values)
      return { minimum: nil, p50: nil, p95: nil, maximum: nil } if values.empty?
      ordered = values.sort
      {
        minimum: ordered.first.round(4),
        p50: percentile(ordered, 0.50),
        p95: percentile(ordered, 0.95),
        maximum: ordered.last.round(4)
      }
    end

    def percentile(values, fraction)
      values.fetch([(values.length * fraction).ceil - 1, 0].max).round(4)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_time - started) * 1000).round(2)
    end

    def artifact_path(filename)
      File.join(@output_dir, filename)
    end

    def load_jsonl(filename)
      path = artifact_path(filename)
      return [] unless File.exist?(path)
      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def append_jsonl(filename, value)
      File.open(artifact_path(filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_jsonl(filename, values)
      File.write(artifact_path(filename), values.map { |value| JSON.generate(value) }.join("\n") + "\n", mode: "w:UTF-8")
    end

    def write_json(filename, value)
      File.write(artifact_path(filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def stringify(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
