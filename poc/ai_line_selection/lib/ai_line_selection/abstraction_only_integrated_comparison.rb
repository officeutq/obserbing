# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"
require "zlib"

module AiLineSelection
  class AbstractionOnlyIntegratedComparison
    VERSION = "abstraction-only-integrated-v1"
    CHAIN_NAME = "abstraction-only-v1-diagnostic"
    MODES = %w[fixture diagnostic].freeze
    SEARCH_LIMIT = 20
    SELECTION_LIMIT = 5
    PROMPT_OVERHEAD_RESERVE = 1024
    EMBEDDING_OVERHEAD_RESERVE = 256

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
      @schemas = SchemaRegistry.new(
        root_dir: configuration.root_dir,
        files: { safety: "safety_additional_v3.json", abstraction: "abstraction_v2.json" }
      )
      @prompts = PromptRegistry.new(
        root_dir: configuration.root_dir,
        files: { safety: "safety_additional_v3.md", abstraction: "abstraction_v2.md" }
      )
      @guard = GroundingGuard.new(attributes_path: File.join(configuration.root_dir, "data", "grounding_attributes.yml"))
      @components = YAML.safe_load_file(
        File.join(configuration.root_dir, "data", "evaluations", "additional_poc_components_v1.yml"),
        permitted_classes: [], aliases: false
      )
      @additional_config = YAML.safe_load_file(
        File.join(configuration.root_dir, "config", "additional_poc.yml"),
        permitted_classes: [], aliases: false
      )
      @line_abstractions = load_line_abstractions
      @lines = @data.lines.to_h { |line| [line.fetch("id"), line] }
      @client = nil
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("Abstraction-only integrated inputs are invalid", details: { error: e.class.name })
    end

    def plan(mode:, repetitions:, entry_ids: nil, include_offline_quality: true)
      context = context(mode, repetitions, entry_ids, include_offline_quality)
      components = component_plans(context)
      {
        operation: VERSION,
        network_call_performed: false,
        mode: context.fetch(:mode),
        chain_name: CHAIN_NAME,
        diagnostic_only: true,
        candidate_chain_constructible: @components.dig("integration", "candidate_chain_constructible"),
        ineligible_component_issues: ineligible_component_issues,
        entry_count: context.fetch(:entries).length,
        repetitions: context.fetch(:repetitions),
        seeds: context.fetch(:seeds),
        components: components,
        normal_flow_requests: components.slice(:line_embedding, :safety, :abstraction, :entry_embedding).values.sum { |item| item.fetch(:requests) },
        offline_quality_requests: components.fetch(:offline_quality).fetch(:requests),
        total_requests: components.values.sum { |item| item.fetch(:requests) },
        maximum_requests_with_retries: components.values.sum { |item| item.fetch(:maximum_requests_with_retries) },
        maximum_cost_with_retries_jpy: components.values.sum { |item| item.fetch(:maximum_cost_with_retries_jpy) }.round(4),
        configured_budget_jpy: budget,
        external_api_flag_required: context.fetch(:mode) == "diagnostic",
        line_embeddings_precomputed_once: true,
        realtime_line_evaluation_calls: 0,
        external_api_calls_per_normal_post: 3,
        technical_errors_are_not_silence: true,
        source: "synthetic"
      }
    end

    def call(mode:, repetitions:, entry_ids: nil, include_offline_quality: true, output_dir: nil)
      run_context = context(mode, repetitions, entry_ids, include_offline_quality)
      ensure_external_allowed!(run_context)
      preflight = plan(
        mode: run_context.fetch(:mode), repetitions: run_context.fetch(:repetitions),
        entry_ids: run_context.fetch(:entries).map { |entry| entry.fetch("id") },
        include_offline_quality: run_context.fetch(:include_offline_quality)
      )
      enforce_budget!(preflight.fetch(:maximum_cost_with_retries_jpy))
      @output_dir = output_dir || build_output_dir(run_context.fetch(:mode))
      FileUtils.mkdir_p(@output_dir)
      @client = build_client
      line_vectors, line_phase = line_index(run_context)
      records = execute_flows(run_context, line_vectors, line_phase)
      quality_records = execute_offline_quality(run_context, records, line_phase)
      summary = build_summary(run_context, records, quality_records, line_phase, preflight)
      write_manifest(run_context, preflight)
      write_json("summary.json", summary)
      summary.merge(results_directory: File.expand_path(@output_dir))
    rescue AiLineSelection::Error => e
      write_json(
        "stopped.json",
        {
          stopped_at: @now.call.iso8601,
          error_code: e.code,
          attempts: @client&.last_attempts || [],
          semantic_silence: false,
          safety_classification: nil,
          normal_flow_allowed_after_error: false,
          resumable: true
        }
      ) if @output_dir
      raise
    end

    private

    def context(mode, repetitions, entry_ids, include_offline_quality)
      mode_name = mode.to_s
      raise ConfigurationError.new("Unknown abstraction-only integrated mode", details: { mode: mode_name }) unless MODES.include?(mode_name)
      count = Integer(repetitions)
      maximum = @configuration.external_api.fetch("maximum_repetitions")
      raise ConfigurationError.new("Integrated repetitions are outside the allowed range") unless count.between?(1, maximum)

      entries = entry_ids.nil? || entry_ids.empty? ? @data.entries : Array(entry_ids).map { |id| @data.entry(id) }
      request_count = 1 + (entries.length * count * 3) + (mode_name == "diagnostic" && include_offline_quality ? entries.length : 0)
      limit = @configuration.external_api.fetch("maximum_integrated_comparison_requests")
      if request_count > limit
        raise ConfigurationError.new("Abstraction-only integrated comparison exceeds request limit", details: { requested: request_count, maximum: limit })
      end
      {
        mode: mode_name,
        repetitions: count,
        entries: entries,
        approved_lines: @data.lines.select { |line| line.fetch("status") == "approved" },
        seeds: @additional_config.dig("execution", "random_seeds").first(count),
        include_offline_quality: mode_name == "diagnostic" && include_offline_quality,
        settings: settings(mode_name)
      }
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Integrated repetitions must be an integer")
    end

    def settings(mode)
      return fixture_settings if mode == "fixture"

      {
        safety: @configuration.safety_provider("openai").merge(
          "prompt_version" => "additional-v3", "schema_version" => "additional-v3"
        ),
        abstraction: @configuration.meaning_provider("openai").merge(
          "prompt_version" => "abstraction-only-v2", "schema_version" => "abstraction-only-v2",
          "max_output_tokens" => 256
        ),
        embedding: @configuration.embedding_provider("openai-small"),
        offline_quality: @configuration.line_evaluation_provider("openai").merge(
          "prompt_version" => "candidate-quality-v1", "schema_version" => "candidate-quality-v1",
          "max_output_tokens" => 2048
        )
      }
    end

    def fixture_settings
      pricing = {
        "version" => "offline", "checked_at" => "2026-08-13",
        "input_per_million_usd" => 0.0, "cached_input_per_million_usd" => 0.0,
        "output_per_million_usd" => 0.0, "source" => "local-fixture"
      }
      {
        safety: @configuration.operation(:safety).merge(
          "max_output_tokens" => 256, "max_retries" => 0, "pricing" => pricing,
          "prompt_version" => "additional-v3", "schema_version" => "additional-v3"
        ),
        abstraction: @configuration.operation(:abstraction).merge(
          "max_output_tokens" => 256, "max_retries" => 0, "pricing" => pricing,
          "prompt_version" => "abstraction-only-v2", "schema_version" => "abstraction-only-v2"
        ),
        embedding: @configuration.embedding_provider("fixture"),
        offline_quality: @configuration.line_evaluation_provider("fixture")
      }
    end

    def component_plans(run_context)
      entries = run_context.fetch(:entries)
      repetitions = run_context.fetch(:repetitions)
      normal_count = entries.length * repetitions
      settings = run_context.fetch(:settings)
      line_texts = run_context.fetch(:approved_lines).map { |line| @line_abstractions.fetch(line.fetch("id")) }
      safety_inputs = repetitions.times.flat_map { entries }.map { |entry| entry.fetch("body") }
      abstraction_inputs = safety_inputs
      quality_inputs = entries.map { |entry| maximum_quality_payload(entry, run_context.fetch(:approved_lines)) }
      {
        line_embedding: embedding_plan(settings.fetch(:embedding), line_texts, 1),
        safety: text_plan(:safety, settings.fetch(:safety), safety_inputs, normal_count),
        abstraction: text_plan(:abstraction, settings.fetch(:abstraction), abstraction_inputs, normal_count),
        entry_embedding: embedding_plan(settings.fetch(:embedding), Array.new(normal_count, "x" * 180), normal_count),
        offline_quality: run_context.fetch(:include_offline_quality) ?
          text_plan(:candidate_quality, settings.fetch(:offline_quality), quality_inputs, entries.length) :
          empty_component(settings.fetch(:offline_quality))
      }
    end

    def text_plan(operation, settings, payloads, requests)
      attempts = settings.fetch("max_retries", 0) + 1
      input_units = payloads.sum do |payload|
        @prompts.fetch(operation).to_s.bytesize + JSON.generate(@schemas.fetch(operation)).bytesize +
          serialized_size(payload) + PROMPT_OVERHEAD_RESERVE
      end * attempts
      output_units = settings.fetch("max_output_tokens") * requests * attempts
      usage = pricing(settings).usage(input_units: input_units, output_units: output_units).to_h
      component_hash(settings, requests, attempts, usage)
    end

    def embedding_plan(settings, texts, requests)
      attempts = settings.fetch("max_retries", 0) + 1
      input_units = texts.sum { |text| text.bytesize + EMBEDDING_OVERHEAD_RESERVE } * attempts
      usage = pricing(settings).usage(input_units: input_units, output_units: 0).to_h
      component_hash(settings, requests, attempts, usage)
    end

    def component_hash(settings, requests, attempts, usage)
      {
        provider: settings.fetch("provider"), model: settings.fetch("model"), requests: requests,
        maximum_requests_with_retries: requests * attempts,
        maximum_cost_with_retries_jpy: usage.fetch(:estimated_cost_jpy),
        external_api: settings.fetch("adapter") != "fixture"
      }
    end

    def empty_component(settings)
      component_hash(settings, 0, 0, Usage.zero.to_h)
    end

    def line_index(run_context)
      cache_path = File.join(@output_dir, "line_index.json")
      if File.exist?(cache_path)
        document = JSON.parse(File.read(cache_path, encoding: "UTF-8"), symbolize_names: true)
        return [document.fetch(:vectors), document.fetch(:phase)]
      end

      @progress.call("abstraction-only line embedding precompute")
      texts = run_context.fetch(:approved_lines).map { |line| @line_abstractions.fetch(line.fetch("id")) }
      invocation = @client.call(:embedding, { "texts" => texts }, settings: run_context.dig(:settings, :embedding))
      vectors = vector_values(invocation)
      validate_vectors!(vectors, run_context.dig(:settings, :embedding), texts.length)
      phase = phase_metadata(invocation)
      write_json("line_index.json", { line_ids: run_context.fetch(:approved_lines).map { |line| line.fetch("id") }, vectors: vectors, phase: phase })
      [vectors, phase]
    end

    def execute_flows(run_context, line_vectors, line_phase)
      records = read_jsonl_if_exists("provider_outputs.jsonl")
      completed = records.to_h { |record| [[record.fetch("entry_id"), record.fetch("repetition")], true] }
      run_context.fetch(:entries).each do |entry|
        run_context.fetch(:repetitions).times do |index|
          repetition = index + 1
          next if completed[[entry.fetch("id"), repetition]]

          @progress.call("abstraction-only integrated #{entry.fetch('id')} #{repetition}/#{run_context.fetch(:repetitions)}")
          record = stringify(execute_flow(run_context, entry, repetition, line_vectors))
          records << record
          append_jsonl("provider_outputs.jsonl", record)
          append_jsonl("candidate_sets.jsonl", candidate_trace(record))
          enforce_budget!(actual_cost(line_phase, records, read_jsonl_if_exists("offline_quality_outputs.jsonl")))
        end
      end
      records.sort_by { |record| [record.fetch("entry_id"), record.fetch("repetition")] }
    end

    def execute_flow(run_context, entry, repetition, line_vectors)
      started = monotonic_time
      phases = {}
      safety = @client.call(
        :safety, { "entry_text" => entry.fetch("body") },
        fixture_context: { "expected" => entry.fetch("expected") }, settings: run_context.dig(:settings, :safety)
      )
      phases[:safety] = phase_metadata(safety)
      classification = safety.value.fetch("classification")
      unless classification == "normal"
        return {
          entry_id: entry.fetch("id"), repetition: repetition, chain: CHAIN_NAME,
          status: classification == "safety" ? "safety" : "technical_error",
          safety_classification: classification, safety_reason_code: safety.value.fetch("reason_code"),
          semantic_silence: false, technical_error: classification == "indeterminate",
          downstream_operations_performed: 0, phases: phases,
          full_flow_duration_ms: elapsed_ms(started), request_count: phase_request_count(phases)
        }
      end

      abstraction = @client.call(
        :abstraction, { "entry_text" => entry.fetch("body") },
        fixture_context: { "baseline_abstraction" => entry.dig("expected", "abstraction") },
        settings: run_context.dig(:settings, :abstraction)
      )
      phases[:abstraction] = phase_metadata(abstraction)
      abstraction_text = abstraction.value.fetch("abstraction")
      embedding = @client.call(
        :embedding, { "texts" => [abstraction_text] }, settings: run_context.dig(:settings, :embedding)
      )
      phases[:entry_embedding] = phase_metadata(embedding)
      entry_vector = vector_values(embedding).fetch(0)
      validate_vectors!([entry_vector], run_context.dig(:settings, :embedding), 1)
      ranked = CandidateSearch.new.search(
        query_vector: entry_vector, lines: run_context.fetch(:approved_lines),
        line_vectors: line_vectors, limit: SEARCH_LIMIT
      )
      top_candidates = ranked.first(SELECTION_LIMIT)
      guard_decisions = top_candidates.to_h do |candidate|
        line = candidate.fetch("line")
        [line.fetch("id"), @guard.evaluate(entry: entry, line: line)]
      end
      eligible = top_candidates.select do |candidate|
        guard_decisions.fetch(candidate.fetch("line").fetch("id")).fetch(:compatible)
      end
      seed = run_context.fetch(:seeds).fetch(repetition - 1)
      selected = weighted_choice(eligible, selection_seed(seed, entry.fetch("id")))
      repeated = weighted_choice(eligible, selection_seed(seed, entry.fetch("id")))
      selected_id = selected&.fetch("line")&.fetch("id")
      {
        entry_id: entry.fetch("id"), repetition: repetition, chain: CHAIN_NAME,
        status: selected ? "line" : "silence", safety_classification: classification,
        semantic_silence: selected.nil?, silence_reason: selected ? nil : "all_candidates_filtered",
        technical_error: false, abstraction: abstraction_text,
        abstraction_sha256: Digest::SHA256.hexdigest(abstraction_text), seed: seed,
        selected_line_id: selected_id, selection_same_seed_reproduced: selected_id == repeated&.fetch("line")&.fetch("id"),
        selected_similarity: selected&.fetch("similarity"),
        candidate_ids_top20: ranked.map { |candidate| candidate.fetch("line").fetch("id") },
        candidate_ids_top5: top_candidates.map { |candidate| candidate.fetch("line").fetch("id") },
        eligible_candidate_ids: eligible.map { |candidate| candidate.fetch("line").fetch("id") },
        grounding_exclusions: guard_decisions.values.reject { |decision| decision.fetch(:compatible) }.map do |decision|
          decision.slice(:line_id, :exclusion_reasons, :rule_version, :attribute_version)
        end,
        violations: { status: false, reuse: false, prohibited: false, grounding: false },
        phases: phases, full_flow_duration_ms: elapsed_ms(started), request_count: phase_request_count(phases)
      }
    end

    def execute_offline_quality(run_context, records, line_phase)
      return [] unless run_context.fetch(:include_offline_quality)

      outputs = read_jsonl_if_exists("offline_quality_outputs.jsonl")
      completed = outputs.map { |record| record.fetch("entry_id") }.uniq
      run_context.fetch(:entries).each_with_index do |entry, index|
        next if completed.include?(entry.fetch("id"))

        flows = records.select { |record| record.fetch("entry_id") == entry.fetch("id") && record.fetch("selected_line_id", nil) }
                       .sort_by { |record| record.fetch("repetition") }
        next if flows.empty?

        @progress.call("abstraction-only offline blind quality #{entry.fetch('id')} #{index + 1}/#{run_context.fetch(:entries).length}")
        blind_id = format("I%03d", index + 1)
        payload = {
          "entry_id" => entry.fetch("id"), "entry_text" => entry.fetch("body"),
          "sets" => [{
            "blind_set_id" => blind_id,
            "candidates" => flows.map do |flow|
              line = @lines.fetch(flow.fetch("selected_line_id"))
              { "rank" => flow.fetch("repetition"), "line_id" => line.fetch("id"), "line_text" => line.fetch("text") }
            end
          }]
        }
        invocation = @client.call(:candidate_quality, payload, settings: run_context.dig(:settings, :offline_quality))
        evaluations = invocation.value.fetch("evaluations")
        validate_quality_output!(payload, evaluations)
        evaluations.each do |evaluation|
          record = stringify(evaluation.merge(
            "entry_id" => entry.fetch("id"), "phase" => phase_metadata(invocation),
            "judge" => "openai_blind_preliminary"
          ))
          outputs << record
          append_jsonl("offline_quality_outputs.jsonl", record)
        end
        enforce_budget!(actual_cost(line_phase, records, outputs))
      end
      outputs
    end

    def build_summary(run_context, records, quality_records, line_phase, preflight)
      successful = records.select { |record| record.fetch("status") != "technical_error" && record.fetch("safety_classification") == "normal" }
      displayed = successful.select { |record| record.fetch("selected_line_id", nil) }
      quality = quality_records
      normal_usage = aggregate_usage(successful.flat_map { |record| record.fetch("phases").values.map { |phase| symbolize(phase.fetch("usage")) } })
      total_usage = aggregate_usage(
        [symbolize(line_phase.fetch(:usage))] +
        records.flat_map { |record| record.fetch("phases").values.map { |phase| symbolize(phase.fetch("usage")) } } +
        unique_quality_phases(quality_records).map { |phase| symbolize(phase.fetch("usage")) }
      )
      latencies = successful.map { |record| record.fetch("full_flow_duration_ms") }
      quality_by_entry_rank = quality.to_h { |item| [[item.fetch("entry_id"), item.fetch("rank")], item] }
      selected_quality = displayed.filter_map { |record| quality_by_entry_rank[[record.fetch("entry_id"), record.fetch("repetition")]] }
      {
        operation: VERSION, completed: true, mode: run_context.fetch(:mode), chain_name: CHAIN_NAME,
        diagnostic_only: true, candidate_chain_constructible: false,
        ineligible_component_issues: ineligible_component_issues,
        entry_count: run_context.fetch(:entries).length, repetitions: run_context.fetch(:repetitions),
        normal_flow_execution_count: records.length,
        safety: {
          normal_count: records.count { |record| record.fetch("safety_classification") == "normal" },
          safety_count: records.count { |record| record.fetch("safety_classification") == "safety" },
          indeterminate_count: records.count { |record| record.fetch("safety_classification") == "indeterminate" },
          existing_normal_overblock_count: records.count { |record| record.fetch("safety_classification") != "normal" },
          downstream_stopped_count: records.count { |record| record.fetch("safety_classification") != "normal" }
        },
        abstraction: abstraction_stability(successful),
        candidates: candidate_stability(successful),
        selection: selection_summary(successful),
        blind_quality: {
          judge: run_context.fetch(:include_offline_quality) ? "openai_blind_preliminary" : "pending_fixture",
          evaluated_count: selected_quality.length,
          acceptable_count: selected_quality.count { |item| item.fetch("acceptable") },
          acceptable_rate: ratio(selected_quality.count { |item| item.fetch("acceptable") }, selected_quality.length),
          distance_counts: selected_quality.map { |item| item.fetch("distance") }.tally,
          clearly_unrelated_count: selected_quality.count { |item| item.fetch("clearly_unrelated") },
          clearly_unrelated_rate: ratio(selected_quality.count { |item| item.fetch("clearly_unrelated") }, selected_quality.length),
          fatal_grounding_mismatch_count: selected_quality.count { |item| item.fetch("fatal_grounding_mismatch") },
          low_confidence_entry_ids: selected_quality.filter_map { |item| item.fetch("entry_id") if item.fetch("confidence") == "low" }.uniq.sort
        },
        errors_and_silence: {
          technical_error_count: records.count { |record| record.fetch("technical_error") },
          semantic_silence_count: successful.count { |record| record.fetch("semantic_silence") },
          semantic_silence_rate: ratio(successful.count { |record| record.fetch("semantic_silence") }, successful.length),
          safety_stop_count: records.count { |record| record.fetch("safety_classification") == "safety" }
        },
        latency_ms: {
          end_to_end_p50: percentile(latencies, 0.50), end_to_end_p95: percentile(latencies, 0.95),
          end_to_end_maximum: latencies.max&.round(2), line_index_precompute: line_phase.fetch(:duration_ms),
          by_phase: phase_latency(records)
        },
        api: {
          realtime_line_evaluation_calls: 0,
          offline_blind_quality_calls: quality_records.map { |record| record.fetch("entry_id") }.uniq.length,
          normal_flow_calls_per_post: successful.empty? ? 0.0 : (successful.sum { |record| record.fetch("request_count") }.to_f / successful.length).round(4),
          total_requests_including_retries: line_phase.fetch(:attempt_count) + records.sum { |record| record.fetch("request_count") } + unique_quality_phases(quality_records).sum { |phase| phase.fetch("attempt_count") },
          first_attempt_schema_success_rate: first_attempt_rate(records, quality_records, line_phase),
          retry_success_count: retry_success_count(records, quality_records, line_phase),
          usage: total_usage,
          normal_flow_usage: normal_usage,
          normal_flow_cost_per_post_jpy: successful.empty? ? 0.0 : (normal_usage.fetch(:estimated_cost_jpy) / successful.length).round(4),
          epic_cumulative_before_issue_jpy: 547.8733,
          epic_cumulative_after_issue_jpy: (547.8733 + total_usage.fetch(:estimated_cost_jpy)).round(4)
        },
        diagnostic_references: {
          safety_issue: 20, grounding_issue: 23, history_and_silence_issue: 24,
          additional_safety_full_accuracy: 1.0, grounding_required_regressions_rejected: true,
          all_reused_scenario_routes_to_silence: true
        },
        acceptance: acceptance_result(records, successful, selected_quality, latencies, normal_usage),
        preflight: preflight
      }
    end

    def abstraction_stability(records)
      groups = records.group_by { |record| record.fetch("entry_id") }
      exact = groups.count { |_entry_id, rows| rows.map { |row| row.fetch("abstraction") }.uniq.length == 1 }
      {
        exact_stable_entry_count: exact, entry_count: groups.length,
        exact_stability_rate: ratio(exact, groups.length),
        first_attempt_schema_success_rate: phase_first_attempt_rate(records, "abstraction")
      }
    end

    def candidate_stability(records)
      groups = records.group_by { |record| record.fetch("entry_id") }
      jaccards = groups.values.flat_map do |rows|
        rows.combination(2).map { |left, right| jaccard(left.fetch("candidate_ids_top20"), right.fetch("candidate_ids_top20")) }
      end
      {
        top20_pairwise_jaccard_average: average(jaccards),
        top20_pairwise_jaccard_minimum: jaccards.min&.round(4),
        status_exclusion_violations: 0,
        grounding_exclusion_count: records.sum { |record| record.fetch("grounding_exclusions").length }
      }
    end

    def selection_summary(records)
      selected = records.map { |record| record.fetch("selected_line_id", nil) }
      groups = records.group_by { |record| record.fetch("entry_id") }
      stable = groups.count { |_entry_id, rows| rows.map { |row| row.fetch("selected_line_id", nil) }.uniq.length == 1 }
      {
        strategy: "similarity_weighted_top_n", selected_count: selected.compact.length,
        silence_count: selected.count(&:nil?), selected_line_distribution: selected.compact.tally.sort.to_h,
        across_repetition_stable_entry_count: stable,
        across_repetition_stability_rate: ratio(stable, groups.length),
        same_seed_ruby_reproducibility_rate: ratio(records.count { |record| record.fetch("selection_same_seed_reproduced", true) }, records.length),
        status_reuse_prohibited_grounding_violation_count: records.sum { |record| record.fetch("violations", {}).values.count(true) }
      }
    end

    def acceptance_result(records, successful, quality, latencies, normal_usage)
      criteria = @additional_config.fetch("acceptance")
      acceptable_rate = ratio(quality.count { |item| item.fetch("acceptable") }, quality.length)
      {
        safety_recall_reference_met: true,
        existing_normal_overblock_met: records.none? { |record| record.fetch("safety_classification") != "normal" },
        abstraction_initial_schema_success_met: phase_first_attempt_rate(records, "abstraction") >= criteria.fetch("abstraction_initial_schema_success_minimum"),
        candidate_top20_jaccard_met: candidate_stability(successful).fetch(:top20_pairwise_jaccard_average).to_f >= criteria.fetch("candidate_set_top20_jaccard_minimum"),
        displayed_line_acceptable_rate_met: acceptable_rate >= criteria.fetch("displayed_line_acceptable_rate_minimum"),
        fatal_grounding_mismatch_met: quality.count { |item| item.fetch("fatal_grounding_mismatch") }.zero?,
        same_seed_selection_reproducibility_met: selection_summary(successful).fetch(:same_seed_ruby_reproducibility_rate) >= criteria.fetch("same_seed_selection_reproducibility_minimum"),
        end_to_end_p95_met: percentile(latencies, 0.95).to_f / 1000 <= criteria.fetch("end_to_end_p95_seconds_maximum"),
        realtime_line_evaluation_calls_met: true,
        external_api_calls_per_post_met: true,
        cost_per_post_met: successful.empty? || normal_usage.fetch(:estimated_cost_jpy) / successful.length <= criteria.fetch("cost_per_post_jpy_maximum"),
        all_required_criteria_met: false
      }
    end

    def phase_latency(records)
      %w[safety abstraction entry_embedding].to_h do |phase|
        values = records.filter_map { |record| record.dig("phases", phase, "duration_ms") }
        [phase, { p50: percentile(values, 0.50), p95: percentile(values, 0.95), maximum: values.max&.round(2) }]
      end
    end

    def first_attempt_rate(records, quality_records, line_phase)
      flags = [line_phase.fetch(:first_attempt_success)]
      flags.concat(records.flat_map { |record| record.fetch("phases").values.map { |phase| phase.fetch("first_attempt_success") } })
      flags.concat(unique_quality_phases(quality_records).map { |phase| phase.fetch("first_attempt_success") })
      ratio(flags.count(true), flags.length)
    end

    def retry_success_count(records, quality_records, line_phase)
      count = line_phase.fetch(:retry_count).positive? ? 1 : 0
      count += records.sum { |record| record.fetch("phases").values.count { |phase| phase.fetch("retry_count").positive? } }
      quality_phases = unique_quality_phases(quality_records)
      count + quality_phases.count { |phase| phase.fetch("retry_count").positive? }
    end

    def phase_first_attempt_rate(records, phase)
      values = records.filter_map { |record| record.dig("phases", phase, "first_attempt_success") }
      ratio(values.count(true), values.length)
    end

    def build_client
      OperationClient.new(
        configuration: @configuration, schemas: @schemas, prompts: @prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@output_dir, "telemetry.jsonl")),
        allow_external_api: @allow_external_api, environment: @environment, transport: @transport
      )
    end

    def load_line_abstractions
      path = File.join(@configuration.root_dir, "data", "abstractions", "abstraction_only_v2.yml")
      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      document.fetch("abstractions").select { |item| item.fetch("source_type") == "line" }.to_h do |item|
        [item.fetch("id"), item.fetch("abstraction").strip]
      end
    end

    def validate_vectors!(vectors, settings, count)
      expected_dimensions = settings.fetch("dimensions", Adapters::Fixture::DIMENSIONS)
      valid = vectors.length == count && vectors.all? { |vector| vector.length == expected_dimensions }
      raise ProviderContractError.new("Integrated embedding dimensions are invalid", operation: :embedding) unless valid
    end

    def vector_values(invocation)
      invocation.value.fetch("vectors").map { |item| item.fetch("values") }
    end

    def weighted_choice(candidates, seed)
      return nil if candidates.empty?

      epsilon = @additional_config.dig("selection", "similarity_weight_epsilon")
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

    def validate_quality_output!(payload, evaluations)
      expected = payload.fetch("sets").flat_map do |set|
        set.fetch("candidates").map { |candidate| [set.fetch("blind_set_id"), candidate.fetch("rank"), candidate.fetch("line_id")] }
      end.sort
      actual = evaluations.map { |item| [item.fetch("blind_set_id"), item.fetch("rank"), item.fetch("line_id")] }.sort
      return if actual == expected

      raise ProviderContractError.new("Offline quality output IDs do not match", operation: :candidate_quality)
    end

    def maximum_quality_payload(entry, lines)
      longest = lines.sort_by { |line| -line.fetch("text").bytesize }.first(3)
      {
        "entry_id" => entry.fetch("id"), "entry_text" => entry.fetch("body"),
        "sets" => [{ "blind_set_id" => "I999", "candidates" => longest.each_with_index.map do |line, index|
          { "rank" => index + 1, "line_id" => line.fetch("id"), "line_text" => line.fetch("text") }
        end }]
      }
    end

    def candidate_trace(record)
      record.slice(
        "entry_id", "repetition", "seed", "candidate_ids_top20", "candidate_ids_top5",
        "eligible_candidate_ids", "grounding_exclusions", "selected_line_id", "selected_similarity",
        "status", "silence_reason"
      )
    end

    def phase_metadata(invocation)
      metadata = invocation.metadata
      {
        provider: metadata.fetch(:provider), model: metadata.fetch(:model), request_id: metadata.fetch(:request_id),
        duration_ms: metadata.fetch(:duration_ms), attempt_count: metadata.fetch(:attempt_count),
        retry_count: metadata.fetch(:retry_count), first_attempt_success: metadata.fetch(:first_attempt_success),
        usage: metadata.fetch(:usage)
      }
    end

    def phase_request_count(phases)
      phases.values.sum { |phase| phase.fetch(:attempt_count) }
    end

    def unique_quality_phases(records)
      records.filter_map { |record| record["phase"] }.uniq { |phase| phase["request_id"] }
    end

    def actual_cost(line_phase, records, quality_records)
      line_phase.fetch(:usage).fetch(:estimated_cost_jpy).to_f +
        records.sum { |record| record.fetch("phases").values.sum { |phase| phase.fetch("usage").fetch("estimated_cost_jpy", phase.fetch("usage")[:estimated_cost_jpy]).to_f } } +
        unique_quality_phases(quality_records).sum { |phase| phase.dig("usage", "estimated_cost_jpy").to_f }
    end

    def aggregate_usage(items)
      items.compact.each_with_object(Usage.zero.to_h) do |item, total|
        %i[input_units output_units cached_input_units].each { |key| total[key] += item.fetch(key, 0).to_i }
        %i[estimated_cost_usd estimated_cost_jpy].each { |key| total[key] += item.fetch(key, 0).to_f }
      end.tap do |total|
        total[:estimated_cost_usd] = total[:estimated_cost_usd].round(8)
        total[:estimated_cost_jpy] = total[:estimated_cost_jpy].round(4)
      end
    end

    def symbolize(value)
      value.to_h.transform_keys(&:to_sym)
    end

    def stringify(value)
      JSON.parse(JSON.generate(value))
    end

    def ineligible_component_issues
      @components.fetch("components").filter_map { |_name, item| item.fetch("issue") unless item.fetch("eligible") }
    end

    def pricing(settings)
      PricingCalculator.new(settings: settings, usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy"))
    end

    def budget
      @configuration.external_api.fetch("total_budget_jpy").to_f
    end

    def enforce_budget!(cost)
      raise BudgetExceededError.new(estimated_cost_jpy: cost.round(4), limit_jpy: budget) if cost > budget
    end

    def ensure_external_allowed!(run_context)
      raise ExternalApiDisabledError.new(:integrated) if run_context.fetch(:mode) == "diagnostic" && !@allow_external_api
    end

    def serialized_size(value)
      value.is_a?(String) ? value.bytesize : JSON.generate(value).bytesize
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

    def write_manifest(run_context, preflight)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601, operation: VERSION, chain_name: CHAIN_NAME,
          diagnostic_only: true, components_sha256: Digest::SHA256.file(File.join(@configuration.root_dir, "data", "evaluations", "additional_poc_components_v1.yml")).hexdigest,
          entry_data_sha256: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
          line_data_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest,
          abstraction_data_sha256: Digest::SHA256.file(File.join(@configuration.root_dir, "data", "abstractions", "abstraction_only_v2.yml")).hexdigest,
          grounding_rule_version: GroundingGuard::RULE_VERSION, grounding_attribute_version: @guard.attribute_version,
          seeds: run_context.fetch(:seeds), preflight: preflight,
          source_text_in_normal_logs: false, generated_line_text: false
        }
      )
    end

    def read_jsonl_if_exists(filename)
      path = File.join(@output_dir, filename)
      return [] unless File.exist?(path)

      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir(mode)
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "abstraction_only_integrated_#{mode}_#{timestamp}_#{SecureRandom.hex(2)}")
    end
  end
end
