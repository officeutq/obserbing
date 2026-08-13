# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"

module AiLineSelection
  class GroundingGuardComparison
    VERSION = "grounding-guard-comparison-v1"

    attr_reader :output_dir

    def initialize(configuration:, now: -> { Time.now.utc })
      @configuration = configuration
      @now = now
      @data = DataLoader.new(configuration)
      @cases_path = File.join(configuration.root_dir, "data", "grounding_guard_cases.yml")
      @attributes_path = File.join(configuration.root_dir, "data", "grounding_attributes.yml")
      @guard = GroundingGuard.new(attributes_path: @attributes_path)
      @entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = @data.lines.to_h { |line| [line.fetch("id"), line] }
    end

    def cases
      @cases ||= YAML.safe_load_file(@cases_path, permitted_classes: [], aliases: false).fetch("cases")
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("Grounding guard cases are invalid", details: { error: e.class.name })
    end

    def plan
      {
        operation: VERSION,
        network_call_performed: false,
        external_api_calls: 0,
        rule_version: GroundingGuard::RULE_VERSION,
        attribute_version: @guard.attribute_version,
        strategies: GroundingGuard::STRATEGIES,
        case_count: cases.length,
        category_counts: cases.map { |item| item.fetch("category") }.tally,
        required_regression_case_ids: cases.filter_map { |item| item.fetch("id") if item["required_regression"] },
        population: { entries: @entries.length, approved_lines: approved_lines.length },
        source_data_mutated: false
      }
    end

    def call(output_dir: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      records = GroundingGuard::STRATEGIES.flat_map { |strategy| evaluate_cases(strategy) }
      strategy_summaries = GroundingGuard::STRATEGIES.to_h do |strategy|
        rows = records.select { |record| record.fetch(:strategy) == strategy }
        [strategy, summarize(rows)]
      end
      chosen = "combined_v1"
      population = evaluate_population(chosen)
      repeated = evaluate_cases(chosen)
      chosen_records = records.select { |record| record.fetch(:strategy) == chosen }
      reproducible = chosen_records == repeated
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      result = {
        operation: VERSION,
        completed: true,
        network_call_performed: false,
        external_api_calls: 0,
        rule_version: GroundingGuard::RULE_VERSION,
        attribute_version: @guard.attribute_version,
        application_order: %w[status reuse recent prohibited grounding],
        strategy_summaries: strategy_summaries,
        selected_strategy: chosen,
        selected_strategy_reproducible: reproducible,
        selected_strategy_population: population,
        duration_ms: (elapsed * 1000).round(3),
        completion: {
          required_regressions_rejected: required_regressions_rejected?(chosen_records),
          fatal_mismatch_misses: strategy_summaries.fetch(chosen).fetch(:false_negative_count),
          compatible_pair_false_exclusions: strategy_summaries.fetch(chosen).fetch(:false_exclusion_count),
          empty_candidate_sets: population.fetch(:empty_candidate_set_count)
        }
      }
      write_jsonl("case_results.jsonl", records)
      write_jsonl("population_exclusions.jsonl", population.fetch(:exclusions))
      write_json("summary.json", result)
      result[:selected_strategy_population] = population.reject { |key| key == :exclusions }
      result.merge(results_directory: File.expand_path(@output_dir))
    end

    private

    def evaluate_cases(strategy)
      cases.map do |test_case|
        entry = case_entry(test_case)
        line = case_line(test_case)
        decision = @guard.evaluate(entry: entry, line: line, strategy: strategy)
        expected = test_case.fetch("expected_compatible")
        decision.merge(
          case_id: test_case.fetch("id"),
          category: test_case.fetch("category"),
          polarity: test_case.fetch("polarity"),
          expected_compatible: expected,
          correct: decision.fetch(:compatible) == expected,
          required_regression: test_case.fetch("required_regression", false)
        )
      end
    end

    def summarize(rows)
      negatives = rows.reject { |row| row.fetch(:expected_compatible) }
      positives = rows.select { |row| row.fetch(:expected_compatible) }
      false_negatives = negatives.select { |row| row.fetch(:compatible) }
      false_exclusions = positives.reject { |row| row.fetch(:compatible) }
      {
        cases: rows.length,
        accuracy: ratio(rows.count { |row| row.fetch(:correct) }, rows.length),
        false_negative_count: false_negatives.length,
        false_negative_case_ids: false_negatives.map { |row| row.fetch(:case_id) },
        false_exclusion_count: false_exclusions.length,
        false_exclusion_rate: ratio(false_exclusions.length, positives.length),
        false_exclusion_case_ids: false_exclusions.map { |row| row.fetch(:case_id) },
        detection_by_category: GroundingGuard::CATEGORIES.to_h do |category|
          category_rows = negatives.select { |row| row.fetch(:category) == category }
          detected = category_rows.count { |row| !row.fetch(:compatible) }
          [category, { detected: detected, total: category_rows.length, rate: ratio(detected, category_rows.length) }]
        end
      }
    end

    def evaluate_population(strategy)
      exclusions = []
      counts = @entries.values.map do |entry|
        allowed = approved_lines.count do |line|
          decision = @guard.evaluate(entry: entry, line: line, strategy: strategy)
          unless decision.fetch(:compatible)
            exclusions << decision.slice(:entry_id, :line_id, :rule_version, :attribute_version, :exclusion_reasons)
          end
          decision.fetch(:compatible)
        end
        { entry_id: entry.fetch("id"), before: approved_lines.length, after: allowed }
      end
      after_counts = counts.map { |row| row.fetch(:after) }.sort
      {
        entry_count: counts.length,
        candidates_before_per_entry: approved_lines.length,
        candidates_after_minimum: after_counts.first,
        candidates_after_median: percentile(after_counts, 0.5),
        candidates_after_maximum: after_counts.last,
        exclusion_count: exclusions.length,
        empty_candidate_set_count: counts.count { |row| row.fetch(:after).zero? },
        empty_candidate_set_rate: ratio(counts.count { |row| row.fetch(:after).zero? }, counts.length),
        silence_rate_from_empty_set: ratio(counts.count { |row| row.fetch(:after).zero? }, counts.length),
        counts: counts,
        exclusions: exclusions
      }
    end

    def required_regressions_rejected?(rows)
      rows.select { |row| row.fetch(:required_regression) }.all? { |row| !row.fetch(:compatible) }
    end

    def case_entry(test_case)
      return @entries.fetch(test_case.fetch("entry_id")) if test_case["entry_id"]

      { "id" => nil, "body" => test_case.fetch("entry_text") }
    end

    def case_line(test_case)
      return @lines.fetch(test_case.fetch("line_id")) if test_case["line_id"]

      { "id" => nil, "text" => test_case.fetch("line_text") }
    end

    def approved_lines
      @approved_lines ||= @lines.values.select { |line| line.fetch("status") == "approved" }
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "grounding_guard_#{timestamp}_#{SecureRandom.hex(2)}")
    end

    def write_json(filename, value)
      File.write(File.join(@output_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def write_jsonl(filename, values)
      File.open(File.join(@output_dir, filename), "w:UTF-8") do |file|
        values.each { |value| file.puts(JSON.generate(value)) }
      end
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end

    def percentile(values, fraction)
      return nil if values.empty?

      values[((values.length - 1) * fraction).ceil]
    end
  end
end
