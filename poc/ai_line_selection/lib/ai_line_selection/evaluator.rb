# frozen_string_literal: true

module AiLineSelection
  class Evaluator
    def initialize(configuration:, adapter: "fixture")
      @configuration = configuration
      @adapter = adapter
      @data = DataLoader.new(configuration)
    end

    def call(repetitions: 1)
      unless (1..10).cover?(repetitions)
        raise ConfigurationError.new("repetitions must be between 1 and 10")
      end

      normal_runs = []
      failures = []

      repetitions.times do |repetition|
        @data.entries.each do |entry|
          runner = build_runner
          result = runner.run_entry(entry)
          normal_runs << {
            entry_id: entry.fetch("id"),
            repetition: repetition + 1,
            status: result.fetch(:status),
            line_id: result.fetch(:line_id),
            candidate_recall: result.dig(:evaluation, :candidate_recall),
            selected_theme_match: result.dig(:evaluation, :selected_theme_match),
            duration_ms: result.dig(:telemetry, :duration_ms),
            estimated_cost_jpy: result.dig(:telemetry, :estimated_cost_jpy)
          }
        rescue AiLineSelection::Error => e
          failures << { entry_id: entry.fetch("id"), repetition: repetition + 1, error_code: e.code }
        end
      end

      safety_runs = @data.safety_cases.filter_map do |safety_case|
        runner = build_runner
        result = runner.classify_safety(safety_case)
        {
          case_id: safety_case.fetch("id"),
          expected: safety_case.fetch("expected").fetch("safety"),
          actual: result.fetch("classification"),
          duration_ms: runner.telemetry.summary.fetch(:duration_ms),
          estimated_cost_jpy: runner.telemetry.summary.fetch(:estimated_cost_jpy)
        }
      rescue AiLineSelection::Error => e
        failures << { case_id: safety_case.fetch("id"), error_code: e.code }
        nil
      end

      build_report(normal_runs, safety_runs, failures, repetitions)
    end

    private

    def build_runner
      Runner.new(
        configuration: @configuration,
        data_loader: @data,
        adapter_override: @adapter,
        telemetry_path: nil
      )
    end

    def build_report(normal_runs, safety_runs, failures, repetitions)
      durations = normal_runs.map { |run| run.fetch(:duration_ms) }
      recalls = normal_runs.filter_map { |run| run.fetch(:candidate_recall) }
      safety_correct = safety_runs.count { |run| run.fetch(:expected) == run.fetch(:actual) }
      line_selections = normal_runs.select { |run| run.fetch(:status) == "line" }
      consistency_groups = normal_runs.group_by { |run| run.fetch(:entry_id) }
      consistent_entries = consistency_groups.count do |_entry_id, runs|
        runs.map { |run| [run.fetch(:status), run.fetch(:line_id)] }.uniq.one?
      end
      estimated_cost = (normal_runs + safety_runs).sum { |run| run.fetch(:estimated_cost_jpy).to_f }

      {
        adapter: @adapter,
        external_api_enabled: @configuration.external_api_enabled?,
        repetitions: repetitions,
        normal_runs: normal_runs.length,
        safety_runs: safety_runs.length,
        failures: failures,
        metrics: {
          structured_flow_success_rate: rate(
            normal_runs.length,
            normal_runs.length + failures.count { |item| item[:entry_id] }
          ),
          candidate_recall_average: recalls.empty? ? nil : (recalls.sum / recalls.length).round(4),
          selected_theme_match_rate: rate(
            line_selections.count { |run| run.fetch(:selected_theme_match) },
            line_selections.length
          ),
          selection_consistency_rate: rate(consistent_entries, consistency_groups.length),
          safety_accuracy: rate(safety_correct, safety_runs.length),
          latency_ms: {
            p50: percentile(durations, 0.50),
            p95: percentile(durations, 0.95),
            max: durations.max
          },
          estimated_cost_jpy: estimated_cost.round(4)
        }
      }
    end

    def rate(numerator, denominator)
      return nil if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def percentile(values, ratio)
      return nil if values.empty?

      sorted = values.sort
      sorted[((sorted.length - 1) * ratio).ceil].round(2)
    end
  end
end
