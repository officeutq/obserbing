# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class IntegratedComparison
    EMBEDDING_VARIANT = "meaning_structure"
    PROVIDER_PROMPT_OVERHEAD_RESERVE = 1024
    EMBEDDING_OVERHEAD_RESERVE = 256
    MODES = %w[fixture selected].freeze

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
      @client = nil
    end

    def plan(mode:, repetitions:, safety_case_repetitions:, entry_ids: nil)
      context = comparison_context(mode, repetitions, safety_case_repetitions, entry_ids)
      components = build_component_plans(context)
      {
        operation: "integrated",
        network_call_performed: false,
        mode: context.fetch(:mode),
        chain_name: context.fetch(:chain_name),
        entry_count: context.fetch(:entries).length,
        normal_flow_repetitions: context.fetch(:repetitions),
        safety_case_count: context.fetch(:safety_cases).length,
        safety_case_repetitions: context.fetch(:safety_case_repetitions),
        candidate_limit: context.fetch(:candidate_limit),
        evaluation_limit: context.fetch(:evaluation_limit),
        components: components,
        total_requests: components.values.sum { |item| item.fetch(:requests) },
        maximum_requests_with_retries: components.values.sum { |item| item.fetch(:maximum_requests_with_retries) },
        maximum_cost_with_one_retry_jpy: components.values.sum { |item| item.fetch(:maximum_cost_with_one_retry_jpy) }.round(4),
        configured_budget_jpy: @configuration.external_api.fetch("total_budget_jpy"),
        external_api_flag_required: context.fetch(:mode) == "selected",
        line_embeddings_precomputed_once: true,
        technical_errors_are_not_silence: true,
        human_evaluation_required_before_final_quality_decision: true
      }
    end

    def call(mode:, repetitions:, safety_case_repetitions:, entry_ids: nil, output_dir: nil)
      context = comparison_context(mode, repetitions, safety_case_repetitions, entry_ids)
      ensure_external_api_allowed!(context)
      preflight = plan(
        mode: context.fetch(:mode),
        repetitions: context.fetch(:repetitions),
        safety_case_repetitions: context.fetch(:safety_case_repetitions),
        entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") }
      )
      enforce_budget!(preflight.fetch(:maximum_cost_with_one_retry_jpy))
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      @client = build_client
      line_vectors, line_embedding = build_line_embeddings(context)
      records = execute_normal_flows(context, line_vectors, line_embedding)
      safety_records = execute_safety_gate(context, line_embedding, records)
      summary = build_summary(context, records, safety_records, line_embedding)
      write_review_artifacts(context, records)
      write_manifest(context, preflight)
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
          normal_flow_allowed_after_error: false
        }
      ) if @output_dir
      raise
    end

    private

    def comparison_context(mode, repetitions, safety_case_repetitions, entry_ids)
      mode_name = mode.to_s
      unless MODES.include?(mode_name)
        raise ConfigurationError.new("Unknown integrated mode", details: { mode: mode_name, allowed: MODES })
      end
      repetition_count = validate_repetitions(repetitions, "normal flow")
      safety_repetition_count = validate_repetitions(safety_case_repetitions, "SAFETY case")
      entries = entry_ids.nil? || entry_ids.empty? ? @data.entries : Array(entry_ids).map { |id| @data.entry(id) }
      safety_cases = @data.safety_cases
      settings = chain_settings(mode_name)
      requests = 1 + (entries.length * repetition_count * 4) + (safety_cases.length * safety_repetition_count)
      maximum = @configuration.external_api.fetch("maximum_integrated_comparison_requests")
      if requests > maximum
        raise ConfigurationError.new(
          "Integrated comparison exceeds the configured request limit",
          details: { requested: requests, maximum: maximum }
        )
      end

      integrated = @configuration.integrated
      {
        mode: mode_name,
        chain_name: mode_name == "fixture" ? "fixture" : integrated.fetch("chain_name"),
        repetitions: repetition_count,
        safety_case_repetitions: safety_repetition_count,
        entries: entries,
        safety_cases: safety_cases,
        approved_lines: @data.lines.select { |line| line.fetch("status") == "approved" },
        candidate_limit: integrated.fetch("candidate_limit"),
        evaluation_limit: integrated.fetch("evaluation_limit"),
        settings: settings
      }
    end

    def validate_repetitions(value, label)
      count = Integer(value)
      maximum = @configuration.external_api.fetch("maximum_repetitions")
      return count if count.between?(1, maximum)

      raise ConfigurationError.new(
        "Integrated #{label} repetitions are outside the allowed range",
        details: { repetitions: count, maximum: maximum }
      )
    rescue ArgumentError, TypeError
      raise ConfigurationError.new("Integrated #{label} repetitions must be an integer")
    end

    def chain_settings(mode)
      return selected_chain_settings if mode == "selected"

      {
        safety: fixture_operation_settings(:safety, max_output_tokens: 256),
        meaning: fixture_operation_settings(:meaning, max_output_tokens: 1024),
        embedding: @configuration.embedding_provider("fixture"),
        line_evaluation: @configuration.line_evaluation_provider("fixture")
      }
    end

    def selected_chain_settings
      integrated = @configuration.integrated
      {
        safety: @configuration.safety_provider(integrated.fetch("safety_provider")),
        meaning: @configuration.meaning_provider(integrated.fetch("meaning_provider")),
        embedding: @configuration.embedding_provider(integrated.fetch("embedding_provider")),
        line_evaluation: @configuration.line_evaluation_provider(integrated.fetch("line_evaluation_provider"))
      }
    end

    def fixture_operation_settings(operation, max_output_tokens:)
      @configuration.operation(operation).merge(
        "max_output_tokens" => max_output_tokens,
        "max_retries" => 0,
        "pricing" => {
          "version" => "offline",
          "checked_at" => "2026-08-12",
          "input_per_million_usd" => 0.0,
          "cached_input_per_million_usd" => 0.0,
          "output_per_million_usd" => 0.0,
          "source" => "local-fixture"
        }
      )
    end

    def build_component_plans(context)
      normal_runs = context.fetch(:entries).length * context.fetch(:repetitions)
      gate_runs = context.fetch(:safety_cases).length * context.fetch(:safety_case_repetitions)
      settings = context.fetch(:settings)
      safety_payloads = repeated_values(context.fetch(:entries).map { |entry| entry.fetch("body") }, context.fetch(:repetitions)) +
                        repeated_values(context.fetch(:safety_cases).map { |item| item.fetch("body") }, context.fetch(:safety_case_repetitions))
      meaning_payloads = repeated_values(context.fetch(:entries).map { |entry| entry.fetch("body") }, context.fetch(:repetitions))
      embedding_texts = context.fetch(:approved_lines).map { |line| @text_builder.line_text(line, EMBEDDING_VARIANT) } +
                        repeated_values(
                          context.fetch(:entries).map { |entry| @text_builder.entry_text(entry, EMBEDDING_VARIANT) },
                          context.fetch(:repetitions)
                        )
      line_payloads = repeated_values(
        context.fetch(:entries).map { |entry| maximum_line_evaluation_payload(context, entry) },
        context.fetch(:repetitions)
      )

      {
        safety: component_plan(:safety, settings.fetch(:safety), safety_payloads, normal_runs + gate_runs),
        meaning: component_plan(:meaning, settings.fetch(:meaning), meaning_payloads, normal_runs),
        embedding: embedding_component_plan(settings.fetch(:embedding), embedding_texts, 1 + normal_runs),
        line_evaluation: component_plan(:line_evaluation, settings.fetch(:line_evaluation), line_payloads, normal_runs)
      }
    end

    def component_plan(operation, settings, payloads, requests)
      input_units = payloads.sum do |payload|
        @prompts.fetch(operation).to_s.bytesize +
          JSON.generate(@schemas.fetch(operation)).bytesize +
          serialized_size(payload) +
          PROVIDER_PROMPT_OVERHEAD_RESERVE
      end
      output_units = settings.fetch("max_output_tokens") * requests
      attempts = settings.fetch("max_retries") + 1
      usage = pricing(settings).usage(
        input_units: input_units * attempts,
        output_units: output_units * attempts
      ).to_h
      component_plan_hash(settings, requests, attempts, usage)
    end

    def embedding_component_plan(settings, texts, requests)
      attempts = settings.fetch("max_retries") + 1
      input_units = texts.sum { |text| text.bytesize + EMBEDDING_OVERHEAD_RESERVE }
      usage = pricing(settings).usage(input_units: input_units * attempts, output_units: 0).to_h
      component_plan_hash(settings, requests, attempts, usage)
    end

    def component_plan_hash(settings, requests, attempts, usage)
      {
        provider: settings.fetch("provider"),
        model: settings.fetch("model"),
        requests: requests,
        maximum_requests_with_retries: requests * attempts,
        maximum_input_units_from_utf8_bytes: usage.fetch(:input_units),
        maximum_output_units: usage.fetch(:output_units),
        maximum_cost_with_one_retry_jpy: usage.fetch(:estimated_cost_jpy),
        external_api: settings.fetch("adapter") != "fixture"
      }
    end

    def maximum_line_evaluation_payload(context, entry)
      longest = context.fetch(:approved_lines).map do |line|
        { "line" => line.slice("id", "text"), "similarity" => -1.0 }
      end.sort_by { |item| -JSON.generate(item).bytesize }.first(context.fetch(:evaluation_limit))
      {
        "meaning" => entry.fetch("expected").slice("themes", "structure", "abstraction"),
        "candidates" => longest
      }
    end

    def repeated_values(values, repetitions)
      repetitions.times.flat_map { values }
    end

    def serialized_size(value)
      value.is_a?(String) ? value.bytesize : JSON.generate(value).bytesize
    end

    def build_line_embeddings(context)
      @progress.call("integrated embedding line precompute")
      texts = context.fetch(:approved_lines).map { |line| @text_builder.line_text(line, EMBEDDING_VARIANT) }
      invocation = @client.call(:embedding, { "texts" => texts }, settings: context.dig(:settings, :embedding))
      vectors = vector_values(invocation)
      validate_embedding_dimensions!(vectors, context.dig(:settings, :embedding))
      [vectors, phase_metadata(invocation)]
    end

    def execute_normal_flows(context, line_vectors, line_embedding)
      records = []
      context.fetch(:entries).each do |entry|
        context.fetch(:repetitions).times do |index|
          @progress.call("integrated normal #{entry.fetch("id")} #{index + 1}/#{context.fetch(:repetitions)}")
          record = execute_normal_flow(context, entry, index + 1, line_vectors)
          records << record
          append_jsonl("provider_outputs.jsonl", record)
          enforce_budget!(usage_cost(line_embedding) + total_record_cost(records))
        end
      end
      records
    end

    def execute_normal_flow(context, entry, repetition, line_vectors)
      phases = {}
      safety = @client.call(
        :safety,
        { "entry_text" => entry.fetch("body") },
        fixture_context: { "expected" => entry.fetch("expected") },
        settings: context.dig(:settings, :safety)
      )
      phases[:safety] = phase_metadata(safety)
      classification = safety.value.fetch("classification")
      return interrupted_normal_record(context, entry, repetition, phases, safety.value) unless classification == "normal"

      meaning = @client.call(
        :meaning,
        { "entry_text" => entry.fetch("body") },
        fixture_context: { "expected" => entry.fetch("expected") },
        settings: context.dig(:settings, :meaning)
      )
      phases[:meaning] = phase_metadata(meaning)
      embedding_text = JSON.generate(meaning.value.slice("themes", "structure", "abstraction"))
      embedding = @client.call(
        :embedding,
        { "texts" => [embedding_text] },
        settings: context.dig(:settings, :embedding)
      )
      phases[:embedding] = phase_metadata(embedding)
      entry_vector = vector_values(embedding).fetch(0)
      validate_embedding_dimensions!([entry_vector], context.dig(:settings, :embedding))
      ranked = CandidateSearch.new.search(
        query_vector: entry_vector,
        lines: context.fetch(:approved_lines),
        line_vectors: line_vectors,
        limit: context.fetch(:candidate_limit)
      )
      candidates = ranked.first(context.fetch(:evaluation_limit))
      append_jsonl(
        "candidate_sets.jsonl",
        {
          entry_id: entry.fetch("id"),
          repetition: repetition,
          candidate_ids: candidates.map { |item| item.fetch("line").fetch("id") },
          candidates: candidates.map do |item|
            { line_id: item.fetch("line").fetch("id"), similarity: item.fetch("similarity") }
          end
        }
      )
      line_input = {
        "meaning" => meaning.value.slice("themes", "structure", "abstraction"),
        "candidates" => candidates.map do |candidate|
          { "line" => candidate.fetch("line").slice("id", "text"), "similarity" => candidate.fetch("similarity") }
        end
      }
      evaluation = @client.call(:line_evaluation, line_input, settings: context.dig(:settings, :line_evaluation))
      phases[:line_evaluation] = phase_metadata(evaluation)
      lines = candidates.map { |item| item.fetch("line") }
      rails_selection = FinalSelector.new(@configuration.selection.fetch("policies").fetch("balanced")).explain(
        evaluation.value.fetch("candidates"),
        lines
      )
      recommendation = evaluation.value.fetch("recommended_line_id")
      ai_line_id = recommendation == "SILENCE" ? nil : recommendation
      quality = quality_metrics(entry, ranked, candidates, rails_selection)
      {
        entry_id: entry.fetch("id"),
        repetition: repetition,
        chain: context.fetch(:chain_name),
        status: rails_selection.fetch(:status),
        technical_error: false,
        semantic_silence: rails_selection.fetch(:status) == "silence",
        safety_classification: classification,
        meaning_sha256: Digest::SHA256.hexdigest(JSON.generate(meaning.value)),
        line_evaluation: evaluation.value,
        ai_line_id: ai_line_id,
        rails_selection: rails_selection,
        ai_rails_same: ai_line_id == rails_selection.fetch(:line_id),
        quality: quality,
        phases: phases,
        full_flow_duration_ms: phase_duration(phases),
        request_count: phase_request_count(phases)
      }
    end

    def interrupted_normal_record(context, entry, repetition, phases, safety)
      classification = safety.fetch("classification")
      {
        entry_id: entry.fetch("id"),
        repetition: repetition,
        chain: context.fetch(:chain_name),
        status: classification == "safety" ? "unexpected_safety" : "technical_error",
        technical_error: classification == "indeterminate",
        semantic_silence: false,
        safety_classification: classification,
        safety_reason_code: safety.fetch("reason_code"),
        downstream_operations_performed: 0,
        phases: phases,
        full_flow_duration_ms: phase_duration(phases),
        request_count: phase_request_count(phases)
      }
    end

    def execute_safety_gate(context, line_embedding, normal_records)
      records = []
      context.fetch(:safety_cases).each do |safety_case|
        context.fetch(:safety_case_repetitions).times do |index|
          @progress.call("integrated safety_gate #{safety_case.fetch("id")} #{index + 1}/#{context.fetch(:safety_case_repetitions)}")
          invocation = @client.call(
            :safety,
            { "entry_text" => safety_case.fetch("body") },
            fixture_context: { "expected" => safety_case.fetch("expected") },
            settings: context.dig(:settings, :safety)
          )
          route = safety_route(invocation.value.fetch("classification"))
          record = {
            case_id: safety_case.fetch("id"),
            repetition: index + 1,
            expected_classification: safety_case.fetch("expected").fetch("safety"),
            actual_classification: invocation.value.fetch("classification"),
            reason_code: invocation.value.fetch("reason_code"),
            confidence: invocation.value.fetch("confidence"),
            route: route,
            downstream_operations_performed: 0,
            phase: phase_metadata(invocation)
          }
          records << record
          append_jsonl("safety_gate.jsonl", record)
          enforce_budget!(usage_cost(line_embedding) + total_record_cost(normal_records) + total_safety_cost(records))
        end
      end
      records
    end

    def safety_route(classification)
      case classification
      when "normal"
        { status: "normal", next_operation: "meaning", normal_flow_allowed: true, safety_response_id: nil }
      when "safety"
        {
          status: "safety",
          next_operation: nil,
          normal_flow_allowed: false,
          safety_response_id: SafetyComparison::SAFETY_RESPONSE_ID
        }
      when "indeterminate"
        {
          status: "technical_error",
          error_code: "safety_indeterminate",
          next_operation: nil,
          normal_flow_allowed: false,
          safety_response_id: nil
        }
      end
    end

    def quality_metrics(entry, ranked, evaluated, selection)
      expected_themes = entry.fetch("expected").fetch("themes")
      relevant_ids = @data.lines.filter_map do |line|
        line.fetch("id") if line.fetch("status") == "approved" && expected_themes.include?(line.fetch("theme"))
      end
      selected_line = @data.lines.find { |line| line.fetch("id") == selection.fetch(:line_id) }
      {
        relevant_line_count: relevant_ids.length,
        candidate_recall_at_50: recall(ranked, relevant_ids),
        candidate_recall_at_20: recall(evaluated, relevant_ids),
        selected_theme_match: selected_line ? expected_themes.include?(selected_line.fetch("theme")) : nil
      }
    end

    def recall(candidates, relevant_ids)
      return nil if relevant_ids.empty?

      ids = candidates.map { |item| item.fetch("line").fetch("id") }
      ((ids & relevant_ids).length.to_f / relevant_ids.length).round(4)
    end

    def build_summary(context, records, safety_records, line_embedding)
      successful = records.select { |record| %w[line silence].include?(record.fetch(:status).to_s) }
      phase_records = records.flat_map do |record|
        record.fetch(:phases).map { |name, metadata| metadata.merge(phase: name.to_s) }
      end
      full_durations = records.map { |record| record.fetch(:full_flow_duration_ms).to_f }
      recalls_20 = successful.filter_map { |record| record.dig(:quality, :candidate_recall_at_20) }
      recalls_50 = successful.filter_map { |record| record.dig(:quality, :candidate_recall_at_50) }
      stability = selection_stability(context, records)
      safety_summary = safety_gate_summary(safety_records)
      usage = sum_usage(
        [symbolize(line_embedding.fetch(:usage))] +
        phase_records.map { |phase| symbolize(phase.fetch(:usage)) } +
        safety_records.map { |record| symbolize(record.dig(:phase, :usage)) }
      )
      first_attempt_rate = ratio(phase_records.count { |phase| phase.fetch(:first_attempt_success) }, phase_records.length)
      all_attempts = [line_embedding] + phase_records + safety_records.map { |record| record.fetch(:phase) }
      all_first_attempt_rate = ratio(
        all_attempts.count { |phase| phase.fetch(:first_attempt_success) },
        all_attempts.length
      )
      full_p95 = percentile(full_durations, 0.95)
      cost_per_post = average(
        phase_records.sum { |phase| symbolize(phase.fetch(:usage)).fetch(:estimated_cost_jpy) },
        records.length,
        4
      )

      {
        operation: "integrated",
        completed: true,
        mode: context.fetch(:mode),
        chain_name: context.fetch(:chain_name),
        entry_count: context.fetch(:entries).length,
        repetitions: context.fetch(:repetitions),
        line_embedding: line_embedding.merge(excluded_from_per_post_latency: true),
        normal_flow: {
          executions: records.length,
          status_counts: records.map { |record| record.fetch(:status).to_s }.tally,
          technical_error_rate: ratio(records.count { |record| record.fetch(:technical_error) }, records.length),
          semantic_silence_rate: ratio(records.count { |record| record.fetch(:semantic_silence) }, records.length),
          first_attempt_schema_success_rate: first_attempt_rate,
          retry_success_count: phase_records.count { |phase| phase.fetch(:retry_count).positive? },
          candidate_recall_at_20_average: average(recalls_20.sum, recalls_20.length, 4),
          candidate_recall_at_50_average: average(recalls_50.sum, recalls_50.length, 4),
          selected_theme_match_rate: ratio(
            successful.count { |record| record.dig(:quality, :selected_theme_match) },
            successful.count { |record| !record.dig(:quality, :selected_theme_match).nil? }
          ),
          ai_rails_same_rate: ratio(successful.count { |record| record.fetch(:ai_rails_same) }, successful.length),
          exact_final_selection_stability: stability,
          full_flow_latency_ms: {
            p50: percentile(full_durations, 0.50),
            p95: full_p95,
            max: full_durations.max&.round(2)
          },
          phase_latency_ms: phase_latency_summary(phase_records),
          estimated_cost_per_post_jpy: cost_per_post
        },
        safety_gate: safety_summary,
        usage: usage,
        total_estimated_cost_jpy: usage.fetch(:estimated_cost_jpy),
        all_operations_first_attempt_schema_success_rate: all_first_attempt_rate,
        human_evaluation: {
          status: "pending_preliminary_review",
          representative_repetition: 1,
          low_confidence_only_human_review_supported: true
        },
        technical_errors_are_not_silence: true,
        adoption_criteria: {
          safety_recall_100_percent: safety_summary.fetch(:safety_recall) == 1.0,
          safety_normal_accuracy_at_least_90_percent: safety_summary.fetch(:normal_accuracy).to_f >= 0.9,
          unsafe_normal_flow_zero: safety_summary.fetch(:unsafe_normal_flow_case_ids).empty?,
          normal_entries_not_blocked_by_safety: records.all? do |record|
            %w[line silence].include?(record.fetch(:status).to_s)
          end,
          first_attempt_schema_success_at_least_99_percent: all_first_attempt_rate.to_f >= 0.99,
          candidate_recall_at_20_at_least_85_percent: average(recalls_20.sum, recalls_20.length, 4).to_f >= 0.85,
          candidate_recall_at_50_at_least_95_percent: average(recalls_50.sum, recalls_50.length, 4).to_f >= 0.95,
          final_selection_stability_at_least_80_percent: stability&.fetch(:rate).to_f >= 0.80,
          full_flow_p95_within_6_seconds: full_p95.to_f <= 6000,
          estimated_cost_per_post_within_5_jpy: cost_per_post.to_f <= 5.0,
          final_quality_decision_pending_human_evaluation: true
        }
      }
    end

    def safety_gate_summary(records)
      expected_safety = records.select { |record| record.fetch(:expected_classification) == "safety" }
      expected_normal = records.select { |record| record.fetch(:expected_classification) == "normal" }
      expected_indeterminate = records.select { |record| record.fetch(:expected_classification) == "indeterminate" }
      unsafe = records.select do |record|
        record.dig(:route, :normal_flow_allowed) && record.fetch(:expected_classification) != "normal"
      end
      actual_safety = records.select { |record| record.fetch(:actual_classification) == "safety" }
      {
        executions: records.length,
        classification_accuracy: ratio(
          records.count { |record| record.fetch(:expected_classification) == record.fetch(:actual_classification) },
          records.length
        ),
        safety_recall: ratio(
          expected_safety.count { |record| record.fetch(:actual_classification) == "safety" },
          expected_safety.length
        ),
        normal_accuracy: ratio(
          expected_normal.count { |record| record.fetch(:actual_classification) == "normal" },
          expected_normal.length
        ),
        indeterminate_accuracy: ratio(
          expected_indeterminate.count { |record| record.fetch(:actual_classification) == "indeterminate" },
          expected_indeterminate.length
        ),
        unsafe_normal_flow_case_ids: unsafe.map { |record| record.fetch(:case_id) }.uniq.sort,
        downstream_operation_count_after_safety: actual_safety.sum { |record| record.fetch(:downstream_operations_performed) },
        first_attempt_schema_success_rate: ratio(
          records.count { |record| record.dig(:phase, :first_attempt_success) },
          records.length
        ),
        retry_success_count: records.count { |record| record.dig(:phase, :retry_count).positive? }
      }
    end

    def selection_stability(context, records)
      return nil unless context.fetch(:repetitions) > 1

      stable = context.fetch(:entries).count do |entry|
        values = records.select { |record| record.fetch(:entry_id) == entry.fetch("id") }
                        .map { |record| [record.fetch(:status), record.dig(:rails_selection, :line_id)] }
        values.length == context.fetch(:repetitions) && values.uniq.length == 1
      end
      { stable_entries: stable, total_entries: context.fetch(:entries).length, rate: ratio(stable, context.fetch(:entries).length) }
    end

    def phase_latency_summary(phases)
      phases.group_by { |phase| phase.fetch(:phase) }.transform_values do |items|
        values = items.map { |item| item.fetch(:duration_ms).to_f }
        { p50: percentile(values, 0.50), p95: percentile(values, 0.95), max: values.max&.round(2) }
      end
    end

    def write_review_artifacts(context, records)
      representative = records.select do |record|
        record.fetch(:repetition) == 1 && %w[line silence].include?(record.fetch(:status).to_s)
      end
      shuffled = representative.shuffle(random: Random.new(@configuration.random_seed)).each_with_index.map do |record, index|
        [format("INT%03d", index + 1), record]
      end
      entries = context.fetch(:entries).to_h { |entry| [entry.fetch("id"), entry] }
      CSV.open(
        File.join(@output_dir, "human_evaluation.csv"),
        "w:UTF-8",
        write_headers: true,
        headers: %w[blind_id entry_id entry_body selected_line_id selected_line_text ai_line_id outcome distance_rating acceptable fatal_violation judge confidence reason needs_human_review human_reviewed notes]
      ) do |csv|
        shuffled.each do |blind_id, record|
          selection = record.fetch(:rails_selection)
          csv << [
            blind_id,
            record.fetch(:entry_id),
            entries.fetch(record.fetch(:entry_id)).fetch("body"),
            selection.fetch(:line_id),
            selection.fetch(:line_text),
            record.fetch(:ai_line_id),
            selection.fetch(:status),
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
        shuffled.each do |blind_id, record|
          csv << [
            blind_id,
            record.fetch(:entry_id),
            record.fetch(:repetition),
            context.fetch(:chain_name),
            chain_model_label(context),
            record.dig(:phases, :line_evaluation, :request_id)
          ]
        end
      end
    end

    def chain_model_label(context)
      %i[safety meaning embedding line_evaluation].map do |operation|
        context.dig(:settings, operation, "model")
      end.join("+")
    end

    def write_manifest(context, preflight)
      write_json(
        "manifest.json",
        {
          created_at: @now.call.iso8601,
          operation: "integrated",
          mode: context.fetch(:mode),
          chain_name: context.fetch(:chain_name),
          providers: context.fetch(:settings).transform_values do |settings|
            settings.slice(
              "provider", "model", "api", "reasoning_effort", "dimensions", "max_output_tokens",
              "timeout_seconds", "max_retries", "pricing"
            )
          end,
          repetitions: context.fetch(:repetitions),
          safety_case_repetitions: context.fetch(:safety_case_repetitions),
          entry_ids: context.fetch(:entries).map { |entry| entry.fetch("id") },
          safety_case_ids: context.fetch(:safety_cases).map { |item| item.fetch("id") },
          approved_line_ids: context.fetch(:approved_lines).map { |line| line.fetch("id") },
          candidate_limit: context.fetch(:candidate_limit),
          evaluation_limit: context.fetch(:evaluation_limit),
          embedding_variant: EMBEDDING_VARIANT,
          prompt_sha256: %i[safety meaning line_evaluation].to_h do |operation|
            [operation, Digest::SHA256.hexdigest(@prompts.fetch(operation))]
          end,
          schema_sha256: %i[safety meaning embedding line_evaluation].to_h do |operation|
            [operation, Digest::SHA256.hexdigest(JSON.generate(@schemas.fetch(operation)))]
          end,
          preflight: preflight,
          body_logged: false,
          technical_errors_are_not_silence: true
        }
      )
    end

    def phase_metadata(invocation)
      {
        provider: invocation.metadata.fetch(:provider),
        model: invocation.metadata.fetch(:model),
        request_id: invocation.metadata.fetch(:request_id),
        duration_ms: invocation.metadata.fetch(:duration_ms),
        attempt_count: invocation.metadata.fetch(:attempt_count),
        retry_count: invocation.metadata.fetch(:retry_count),
        first_attempt_success: invocation.metadata.fetch(:first_attempt_success),
        usage: invocation.metadata.fetch(:usage)
      }
    end

    def phase_duration(phases)
      phases.values.sum { |metadata| metadata.fetch(:duration_ms).to_f }.round(2)
    end

    def phase_request_count(phases)
      phases.values.sum { |metadata| metadata.fetch(:attempt_count) }
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

    def ensure_external_api_allowed!(context)
      raise ExternalApiDisabledError.new(:integrated) if context.fetch(:mode) == "selected" && !@allow_external_api
    end

    def enforce_budget!(cost)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: cost.round(4), limit_jpy: limit) if cost > limit
    end

    def pricing(settings)
      PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      )
    end

    def validate_embedding_dimensions!(vectors, settings)
      dimensions = vectors.map(&:length).uniq
      return if dimensions == [settings.fetch("dimensions")]

      raise ProviderContractError.new(
        "Integrated Embedding dimensions do not match configuration",
        operation: :embedding,
        details: { expected: settings.fetch("dimensions"), actual: dimensions }
      )
    end

    def vector_values(invocation)
      invocation.value.fetch("vectors").map { |item| item.fetch("values") }
    end

    def usage_cost(metadata)
      symbolize(metadata.fetch(:usage)).fetch(:estimated_cost_jpy)
    end

    def total_record_cost(records)
      records.sum do |record|
        record.fetch(:phases).values.sum { |phase| usage_cost(phase) }
      end
    end

    def total_safety_cost(records)
      records.sum { |record| usage_cost(record.fetch(:phase)) }
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

    def percentile(values, fraction)
      return nil if values.empty?

      ordered = values.sort
      ordered.fetch([(ordered.length * fraction).ceil - 1, 0].max).round(2)
    end

    def ratio(numerator, denominator)
      return nil if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count, precision)
      return nil if count.zero?

      (total.to_f / count).round(precision)
    end

    def symbolize(value)
      value.transform_keys(&:to_sym)
    end

    def append_jsonl(filename, value)
      File.open(File.join(@output_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "integrated_#{timestamp}_#{SecureRandom.hex(2)}")
    end
  end
end
