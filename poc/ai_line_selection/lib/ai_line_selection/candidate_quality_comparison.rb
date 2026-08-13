# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "securerandom"

module AiLineSelection
  class CandidateQualityComparison
    VERSION = "candidate-quality-v1"
    CANDIDATE_LIMIT = 5

    def initialize(
      configuration:,
      results_dir:,
      allow_external_api: false,
      environment: ENV,
      transport: nil,
      progress: nil
    )
      @configuration = configuration
      @results_dir = File.expand_path(results_dir)
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @progress = progress || ->(_message) {}
      @data = DataLoader.new(configuration)
      @records = read_jsonl("candidate_sets.jsonl")
      @mapping = CSV.read(File.join(@results_dir, "blind_mapping.csv"), headers: true, encoding: "UTF-8")
      @comparison = read_json("summary.json")
      validate_source!
    end

    def plan(provider:)
      settings = @configuration.line_evaluation_provider(provider)
      requests = @data.entries.length
      maximum_usage = PricingCalculator.new(
        settings: settings,
        usd_to_jpy: @configuration.external_api.fetch("usd_to_jpy")
      ).usage(
        input_units: payloads.sum { |payload| JSON.generate(payload).bytesize },
        output_units: requests * settings.fetch("max_output_tokens")
      ).to_h
      {
        operation: VERSION,
        network_call_performed: false,
        provider: settings.slice("adapter", "provider", "model", "max_output_tokens", "timeout_seconds", "max_retries", "pricing"),
        entry_count: @data.entries.length,
        blind_set_count: @mapping.length,
        candidates_per_set: CANDIDATE_LIMIT,
        candidate_evaluations: @mapping.length * CANDIDATE_LIMIT,
        total_requests: requests,
        maximum_requests_with_retries: requests * (settings.fetch("max_retries", 0) + 1),
        maximum_cost_with_retries_jpy: (maximum_usage.fetch(:estimated_cost_jpy) * (settings.fetch("max_retries", 0) + 1)).round(4),
        configured_budget_jpy: @configuration.external_api.fetch("total_budget_jpy"),
        external_api_flag_required: settings.fetch("adapter") != "fixture",
        source_texts_blinded_to_mode: true,
        synthetic_data_only: true
      }
    end

    def call(provider:)
      settings = @configuration.line_evaluation_provider(provider)
      raise ExternalApiDisabledError.new(:candidate_quality) if settings.fetch("adapter") != "fixture" && !@allow_external_api

      preflight = plan(provider: provider)
      enforce_budget!(preflight.fetch(:maximum_cost_with_retries_jpy))
      client = OperationClient.new(
        configuration: @configuration,
        schemas: SchemaRegistry.new(root_dir: @configuration.root_dir),
        prompts: PromptRegistry.new(root_dir: @configuration.root_dir),
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: File.join(@results_dir, "candidate_quality_telemetry.jsonl")),
        allow_external_api: @allow_external_api,
        environment: @environment,
        transport: @transport
      )
      outputs = existing_outputs
      completed_entry_ids = outputs.map { |record| record.fetch("entry_id") }.uniq
      usage = existing_usage
      remaining_payloads = payloads.reject { |payload| completed_entry_ids.include?(payload.fetch("entry_id")) }
      remaining_payloads.each_with_index do |payload, index|
        entry_id = payload.fetch("entry_id")
        @progress.call("candidate quality #{entry_id} #{index + 1}/#{remaining_payloads.length} (#{completed_entry_ids.length} resumed)")
        invocation = client.call(:candidate_quality, payload, settings: settings)
        evaluations = invocation.value.fetch("evaluations")
        validate_evaluations!(payload, evaluations)
        evaluations.each do |evaluation|
          record = evaluation.merge(
            "entry_id" => entry_id,
            "evaluator_provider" => invocation.metadata.fetch(:provider),
            "evaluator_model" => invocation.metadata.fetch(:model)
          )
          outputs << record
          append_jsonl("candidate_quality_outputs.jsonl", record)
        end
        usage = add_usage(usage, invocation.metadata.fetch(:usage))
        enforce_budget!(usage.fetch(:estimated_cost_jpy))
      end
      decoded = decode_modes(outputs)
      mode_summaries = summarize_modes(decoded)
      human_ids = decoded.filter_map do |record|
        record.fetch("entry_id") if record.fetch("confidence") == "low" || record.fetch("fatal_grounding_mismatch")
      end.uniq.sort
      best_mode = eligible_abstraction_modes(mode_summaries).max_by do |mode|
        summary = mode_summaries.fetch(mode)
        [summary.fetch(:entries_with_acceptable_candidate_rate), summary.fetch(:acceptable_rate), -summary.fetch(:clearly_unrelated_rate)]
      end
      result = {
        operation: VERSION,
        completed: true,
        judge: "codex_preliminary",
        methodology: {
          mode_hidden: true,
          evaluated_top_n: CANDIDATE_LIMIT,
          all_entries_evaluated: true,
          theme_and_similarity_hidden: true
        },
        evaluator_counts: evaluator_counts(decoded),
        mode_summaries: mode_summaries,
        recommended_abstraction_mode_by_quality: best_mode,
        human_review_required_entry_ids: human_ids,
        human_review_required_count: human_ids.length,
        usage: usage,
        realtime_line_evaluation_calls: 0,
        offline_candidate_quality_calls: payloads.length,
        resumed_completed_entry_count: completed_entry_ids.length,
        preflight: preflight
      }
      write_json("candidate_quality_summary.json", result)
      update_comparison_summary(result)
      result.merge(summary_file: File.join(@results_dir, "candidate_quality_summary.json"))
    end

    private

    def payloads
      @payloads ||= begin
        entries_by_id = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
        lines_by_id = @data.lines.to_h { |line| [line.fetch("id"), line] }
        records = @records.select { |record| record.fetch("repetition") == 1 }.to_h do |record|
          [[record.fetch("entry_id"), record.fetch("mode")], record]
        end
        entries_by_id.map do |entry_id, entry|
          rows = @mapping.select { |row| row.fetch("entry_id") == entry_id }
          {
            "entry_id" => entry_id,
            "entry_text" => entry.fetch("body"),
            "sets" => rows.map do |row|
              candidates = records.fetch([entry_id, row.fetch("mode")]).fetch("top_candidates").first(CANDIDATE_LIMIT)
              {
                "blind_set_id" => row.fetch("blind_set_id"),
                "candidates" => candidates.map do |candidate|
                  {
                    "rank" => candidate.fetch("rank"),
                    "line_id" => candidate.fetch("line_id"),
                    "line_text" => lines_by_id.fetch(candidate.fetch("line_id")).fetch("text")
                  }
                end
              }
            end
          }
        end
      end
    end

    def validate_evaluations!(payload, evaluations)
      expected = payload.fetch("sets").flat_map do |set|
        set.fetch("candidates").map do |candidate|
          [set.fetch("blind_set_id"), candidate.fetch("rank"), candidate.fetch("line_id")]
        end
      end.sort
      actual = evaluations.map do |evaluation|
        [evaluation.fetch("blind_set_id"), evaluation.fetch("rank"), evaluation.fetch("line_id")]
      end.sort
      return if actual == expected

      raise ProviderContractError.new(
        "Candidate quality response IDs do not match the blind input",
        operation: :candidate_quality,
        details: { expected_count: expected.length, actual_count: actual.length }
      )
    end

    def decode_modes(outputs)
      modes = @mapping.to_h { |row| [row.fetch("blind_set_id"), row.fetch("mode")] }
      outputs.map { |record| record.merge("mode" => modes.fetch(record.fetch("blind_set_id"))) }
    end

    def summarize_modes(records)
      records.group_by { |record| record.fetch("mode") }.transform_values do |items|
        by_entry = items.group_by { |item| item.fetch("entry_id") }
        acceptable = items.count { |item| item.fetch("acceptable") }
        unrelated = items.count { |item| item.fetch("clearly_unrelated") }
        fatal = items.count { |item| item.fetch("fatal_grounding_mismatch") }
        entries_with_acceptable = by_entry.count { |_id, candidates| candidates.any? { |item| item.fetch("acceptable") } }
        {
          evaluated_entries: by_entry.length,
          evaluated_candidates: items.length,
          acceptable_count: acceptable,
          acceptable_rate: ratio(acceptable, items.length),
          entries_with_acceptable_candidate: entries_with_acceptable,
          entries_with_acceptable_candidate_rate: ratio(entries_with_acceptable, by_entry.length),
          clearly_unrelated_count: unrelated,
          clearly_unrelated_rate: ratio(unrelated, items.length),
          fatal_grounding_mismatch_count: fatal,
          distance_counts: items.map { |item| item.fetch("distance") }.tally.sort.to_h,
          confidence_counts: items.map { |item| item.fetch("confidence") }.tally.sort.to_h,
          evaluator_counts: evaluator_counts(items),
          unacceptable_entry_ids: by_entry.filter_map do |entry_id, candidates|
            entry_id unless candidates.any? { |item| item.fetch("acceptable") }
          end
        }
      end
    end

    def evaluator_counts(records)
      records.map do |record|
        provider = record.fetch("evaluator_provider", "openai")
        model = record.fetch("evaluator_model", "gpt-5.6-terra")
        "#{provider}/#{model}"
      end.tally.sort.to_h
    end

    def eligible_abstraction_modes(summaries)
      summaries.keys.select { |mode| mode.start_with?("abstraction_only_v2") }
    end

    def update_comparison_summary(quality)
      mode = quality.fetch(:recommended_abstraction_mode_by_quality)
      summary = quality.fetch(:mode_summaries).fetch(mode)
      @comparison["blind_candidate_evaluation_pending"] = false
      @comparison["codex_preliminary_candidate_quality"] = {
        "status" => "complete",
        "summary_file" => File.join(@results_dir, "candidate_quality_summary.json"),
        "recommended_mode" => mode,
        "human_review_required_count" => quality.fetch(:human_review_required_count)
      }
      criteria = @comparison.fetch("adoption_criteria")
      criteria["entries_with_acceptable_candidate_at_least_95_percent"] =
        summary.fetch(:entries_with_acceptable_candidate_rate) >= 0.95
      criteria["blind_candidate_quality_pending"] = false
      criteria["eligible_for_ruby_selection_comparison"] =
        criteria.fetch("candidate_or_retired_mixing_zero") &&
        criteria.fetch("fixed_abstraction_search_determinism_100_percent") &&
        criteria.fetch("repeated_abstraction_top20_jaccard_at_least_0_80") &&
        criteria.fetch("entries_with_acceptable_candidate_at_least_95_percent") &&
        summary.fetch(:fatal_grounding_mismatch_count).zero?
      write_json("summary.json", @comparison)
    end

    def validate_source!
      unless @comparison.fetch("operation") == AbstractionEmbeddingComparison::VERSION && @comparison.fetch("completed")
        raise DataError.new("Candidate quality source comparison is invalid")
      end
      unless @mapping.length == @data.entries.length * AbstractionEmbeddingComparison::MODES.length
        raise DataError.new("Blind candidate mapping is incomplete")
      end
    rescue Errno::ENOENT, CSV::MalformedCSVError, KeyError, JSON::ParserError => e
      raise DataError.new("Candidate quality source is invalid", details: { error_class: e.class.name })
    end

    def existing_outputs
      path = File.join(@results_dir, "candidate_quality_outputs.jsonl")
      return [] unless File.exist?(path)

      records = read_jsonl("candidate_quality_outputs.jsonl")
      invalid = records.group_by { |record| record.fetch("entry_id") }.select do |_entry_id, items|
        items.length != AbstractionEmbeddingComparison::MODES.length * CANDIDATE_LIMIT
      end
      unless invalid.empty?
        raise DataError.new(
          "Candidate quality resume data contains an incomplete Entry",
          details: { entry_ids: invalid.keys.sort }
        )
      end
      records
    end

    def existing_usage
      path = File.join(@results_dir, "candidate_quality_telemetry.jsonl")
      return Usage.zero.to_h unless File.exist?(path)

      records = File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
      successful = records.select { |record| %w[success retry_success].include?(record.fetch("status")) }
      add_usage(*successful.map do |record|
        {
          input_units: record.fetch("input_units", 0),
          output_units: record.fetch("output_units", 0),
          cached_input_units: record.fetch("cached_input_units", 0),
          estimated_cost_usd: record.fetch("estimated_cost_usd", 0.0),
          estimated_cost_jpy: record.fetch("estimated_cost_jpy", 0.0)
        }
      end)
    end

    def enforce_budget!(cost)
      limit = @configuration.external_api.fetch("total_budget_jpy").to_f
      raise BudgetExceededError.new(estimated_cost_jpy: cost, limit_jpy: limit) if cost > limit
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

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def read_json(filename)
      JSON.parse(File.read(File.join(@results_dir, filename), encoding: "UTF-8"))
    end

    def read_jsonl(filename)
      File.readlines(File.join(@results_dir, filename), encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def append_jsonl(filename, value)
      File.open(File.join(@results_dir, filename), "a:UTF-8") { |file| file.puts(JSON.generate(value)) }
    end

    def write_json(filename, value)
      File.write(File.join(@results_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end
  end
end
