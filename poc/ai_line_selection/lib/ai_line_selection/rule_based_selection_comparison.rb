# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"
require "zlib"

module AiLineSelection
  class RuleBasedSelectionComparison
    VERSION = "ruby-line-selection-v1"
    INPUT_VERSION = SelectionInputSnapshot::VERSION
    STRATEGIES = %w[top1 uniform_top_n similarity_weighted_top_n threshold_uniform].freeze
    SCENARIOS = %w[history_none top1_reused top5_multiple_reused same_meaning_recent all_candidates_reused].freeze

    attr_reader :output_dir

    def initialize(configuration:, snapshot_path: nil, now: -> { Time.now.utc })
      @configuration = configuration
      @now = now
      @data = DataLoader.new(configuration)
      @snapshot_path = snapshot_path || File.join(configuration.root_dir, "data", "evaluations", "ruby_selection_inputs_v1.json")
      @snapshot = JSON.parse(File.read(@snapshot_path, encoding: "UTF-8"), symbolize_names: true)
      validate_snapshot!
      @entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = @data.lines.to_h { |line| [line.fetch("id"), line] }
      @guard = GroundingGuard.new(attributes_path: File.join(configuration.root_dir, "data", "grounding_attributes.yml"))
      additional_config = YAML.safe_load_file(
        File.join(configuration.root_dir, "config", "additional_poc.yml"),
        permitted_classes: [],
        aliases: false
      )
      @settings = additional_config.fetch("selection")
      @acceptance = additional_config.fetch("acceptance")
      @seeds = additional_config.dig("execution", "random_seeds")
    rescue Errno::ENOENT, JSON::ParserError, KeyError => e
      raise DataError.new("Ruby selection snapshot is invalid", details: { error: e.class.name, path: @snapshot_path })
    end

    def plan
      {
        operation: VERSION,
        network_call_performed: false,
        external_api_calls: 0,
        input_version: @snapshot.fetch(:version),
        candidate_mode: @snapshot.fetch(:mode),
        entry_count: @snapshot.fetch(:entries).length,
        candidates_per_entry: @snapshot.fetch(:quality_top_n),
        strategies: STRATEGIES,
        scenarios: SCENARIOS,
        seeds: @seeds,
        executions: @snapshot.fetch(:entries).length * STRATEGIES.length * SCENARIOS.length * @seeds.length,
        rule_version: GroundingGuard::RULE_VERSION,
        attribute_version: @guard.attribute_version,
        realtime_line_evaluation_calls: 0
      }
    end

    def call(output_dir: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @output_dir = output_dir || build_output_dir
      FileUtils.mkdir_p(@output_dir)
      selections = execute_all
      repeated = execute_all
      reproducibility = ratio(selections.zip(repeated).count { |left, right| signature(left) == signature(right) }, selections.length)
      strategy_summaries = STRATEGIES.to_h do |strategy|
        [strategy, summarize_strategy(selections.select { |row| row.fetch(:strategy) == strategy })]
      end
      recommended = eligible_strategies(strategy_summaries).max_by do |strategy|
        summary = strategy_summaries.fetch(strategy)
        [summary.fetch(:blind_quality).fetch(:acceptable_rate), -summary.fetch(:blind_quality).fetch(:clearly_unrelated_rate)]
      end
      best_diagnostic = STRATEGIES.max_by do |strategy|
        summary = strategy_summaries.fetch(strategy)
        [summary.fetch(:blind_quality).fetch(:acceptable_rate), -summary.fetch(:blind_quality).fetch(:clearly_unrelated_rate)]
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      result = {
        operation: VERSION,
        completed: true,
        network_call_performed: false,
        external_api_calls: 0,
        realtime_line_evaluation_calls: 0,
        input_version: @snapshot.fetch(:version),
        source_hashes: @snapshot.fetch(:source_hashes),
        rule_version: GroundingGuard::RULE_VERSION,
        attribute_version: @guard.attribute_version,
        application_order: %w[status reuse recent prohibited grounding strategy_quality_condition],
        seeds: @seeds,
        same_seed_reproducibility_rate: reproducibility,
        strategy_summaries: strategy_summaries,
        recommended_strategy: recommended,
        diagnostic_best_strategy: best_diagnostic,
        all_strategies_rejected: recommended.nil?,
        duration_ms: (elapsed * 1000).round(3),
        violations: {
          status: selections.count { |row| row.fetch(:violations).fetch(:status) },
          reuse: selections.count { |row| row.fetch(:violations).fetch(:reuse) },
          recent_meaning: selections.count { |row| row.fetch(:violations).fetch(:recent_meaning) },
          prohibited: selections.count { |row| row.fetch(:violations).fetch(:prohibited) },
          grounding: selections.count { |row| row.fetch(:violations).fetch(:grounding) }
        }
      }
      write_jsonl("selections.jsonl", selections)
      write_json("summary.json", result)
      result.merge(results_directory: File.expand_path(@output_dir))
    end

    private

    def execute_all
      @snapshot.fetch(:entries).flat_map do |source|
        STRATEGIES.flat_map do |strategy|
          SCENARIOS.flat_map do |scenario|
            @seeds.map { |seed| execute(source, strategy, scenario, seed) }
          end
        end
      end
    end

    def execute(source, strategy, scenario, seed)
      entry_id = source.fetch(:entry_id)
      entry = @entries.fetch(entry_id)
      original = source.fetch(:candidates)
      history = history_for(original, scenario)
      after_status = original.select { |candidate| @lines.fetch(candidate.fetch(:line_id)).fetch("status") == "approved" }
      after_reuse = after_status.reject { |candidate| history.fetch(:reused_line_ids).include?(candidate.fetch(:line_id)) }
      after_recent = after_reuse.reject do |candidate|
        history.fetch(:recent_meanings).include?(@lines.fetch(candidate.fetch(:line_id)).fetch("meaning"))
      end
      after_prohibited = after_recent.reject { |candidate| history.fetch(:prohibited_line_ids).include?(candidate.fetch(:line_id)) }
      guard_decisions = after_prohibited.to_h do |candidate|
        line = @lines.fetch(candidate.fetch(:line_id))
        [candidate.fetch(:line_id), @guard.evaluate(entry: entry, line: line)]
      end
      after_grounding = after_prohibited.select { |candidate| guard_decisions.fetch(candidate.fetch(:line_id)).fetch(:compatible) }
      pool = strategy_pool(after_grounding, strategy)
      selected = choose(pool, strategy, deterministic_seed(seed, entry_id, scenario, strategy))
      line = selected && @lines.fetch(selected.fetch(:line_id))
      {
        entry_id: entry_id,
        strategy: strategy,
        scenario: scenario,
        seed: seed,
        selected_line_id: selected&.fetch(:line_id),
        outcome: selected ? "line" : "silence",
        silence_reason: silence_reason(after_grounding, pool),
        similarity: selected&.fetch(:similarity),
        blind_quality: selected&.fetch(:blind_quality),
        candidate_counts: {
          input: original.length,
          after_status: after_status.length,
          after_reuse: after_reuse.length,
          after_recent: after_recent.length,
          after_prohibited: after_prohibited.length,
          after_grounding: after_grounding.length,
          strategy_pool: pool.length
        },
        exclusions: {
          grounding: guard_decisions.values.reject { |decision| decision.fetch(:compatible) }.map do |decision|
            decision.slice(:line_id, :exclusion_reasons, :rule_version, :attribute_version)
          end
        },
        violations: {
          status: line && line.fetch("status") != "approved",
          reuse: selected && history.fetch(:reused_line_ids).include?(selected.fetch(:line_id)),
          recent_meaning: line && history.fetch(:recent_meanings).include?(line.fetch("meaning")),
          prohibited: selected && history.fetch(:prohibited_line_ids).include?(selected.fetch(:line_id)),
          grounding: selected && !guard_decisions.fetch(selected.fetch(:line_id)).fetch(:compatible)
        }
      }
    end

    def history_for(candidates, scenario)
      reused = []
      recent = []
      case scenario
      when "top1_reused"
        reused = [candidates.first.fetch(:line_id)]
      when "top5_multiple_reused"
        reused = candidates.first(3).map { |candidate| candidate.fetch(:line_id) }
      when "same_meaning_recent"
        recent = [@lines.fetch(candidates.first.fetch(:line_id)).fetch("meaning")]
      when "all_candidates_reused"
        reused = candidates.map { |candidate| candidate.fetch(:line_id) }
      end
      { reused_line_ids: reused, recent_meanings: recent, prohibited_line_ids: [] }
    end

    def strategy_pool(candidates, strategy)
      case strategy
      when "top1" then candidates.first(1)
      when "uniform_top_n", "similarity_weighted_top_n" then candidates.first(@settings.fetch("random_top_n"))
      when "threshold_uniform"
        candidates.select { |candidate| candidate.fetch(:similarity) >= @settings.fetch("similarity_threshold") }
                  .first([@settings.fetch("threshold_max_candidates"), @snapshot.fetch(:quality_top_n)].min)
      end
    end

    def choose(pool, strategy, seed)
      return nil if pool.empty?
      return pool.first if strategy == "top1"

      random = Random.new(seed)
      return pool.fetch(random.rand(pool.length)) unless strategy == "similarity_weighted_top_n"

      epsilon = @settings.fetch("similarity_weight_epsilon")
      weights = pool.map { |candidate| [candidate.fetch(:similarity) + epsilon, epsilon].max }
      cursor = random.rand * weights.sum
      pool.zip(weights).each do |candidate, weight|
        cursor -= weight
        return candidate if cursor <= 0
      end
      pool.last
    end

    def summarize_strategy(rows)
      normal = rows.select { |row| row.fetch(:scenario) == "history_none" }
      displayed = normal.select { |row| row.fetch(:outcome) == "line" }
      quality = displayed.map { |row| row.fetch(:blind_quality) }
      all_silence = rows.count { |row| row.fetch(:outcome) == "silence" }
      per_entry_diversity = normal.group_by { |row| row.fetch(:entry_id) }.values.map do |entry_rows|
        entry_rows.map { |row| row.fetch(:selected_line_id) }.compact.uniq.length
      end
      {
        executions: rows.length,
        blind_quality_population: "history_none_fixed_seeds",
        blind_quality: {
          displayed_count: displayed.length,
          acceptable_count: quality.count { |item| item.fetch(:acceptable) },
          acceptable_rate: ratio(quality.count { |item| item.fetch(:acceptable) }, quality.length),
          distance_counts: quality.map { |item| item.fetch(:distance) }.tally,
          clearly_unrelated_count: quality.count { |item| item.fetch(:clearly_unrelated) },
          clearly_unrelated_rate: ratio(quality.count { |item| item.fetch(:clearly_unrelated) }, quality.length),
          fatal_grounding_mismatch_count: quality.count { |item| item.fetch(:fatal_grounding_mismatch) },
          not_obserbing_count: quality.count { |item| item.fetch(:distance) == "not_obserbing" },
          not_obserbing_rate: ratio(quality.count { |item| item.fetch(:distance) == "not_obserbing" }, quality.length)
        },
        silence_count: all_silence,
        silence_rate: ratio(all_silence, rows.length),
        history_none_silence_rate: ratio(normal.count { |row| row.fetch(:outcome) == "silence" }, normal.length),
        average_unique_outputs_per_entry_across_seeds: (per_entry_diversity.sum.to_f / per_entry_diversity.length).round(4),
        selected_line_distribution: displayed.map { |row| row.fetch(:selected_line_id) }.tally.sort.to_h,
        violation_count: rows.sum { |row| row.fetch(:violations).values.count(true) },
        average_candidates_after_grounding: (rows.sum { |row| row.dig(:candidate_counts, :after_grounding) }.to_f / rows.length).round(4)
      }
    end

    def eligible_strategies(summaries)
      summaries.filter_map do |strategy, summary|
        quality = summary.fetch(:blind_quality)
        strategy if quality.fetch(:acceptable_rate) >= @acceptance.fetch("displayed_line_acceptable_rate_minimum") &&
                    quality.fetch(:fatal_grounding_mismatch_count).zero? &&
                    quality.fetch(:clearly_unrelated_rate) <= @acceptance.fetch("clearly_unrelated_rate_maximum") &&
                    quality.fetch(:not_obserbing_rate) <= @acceptance.fetch("not_obserbing_rate_maximum") &&
                    summary.fetch(:silence_rate) <= @acceptance.fetch("silence_rate_maximum") &&
                    summary.fetch(:violation_count).zero?
      end
    end

    def validate_snapshot!
      raise DataError.new("Unsupported Ruby selection snapshot version") unless @snapshot.fetch(:version) == INPUT_VERSION
      raise DataError.new("Ruby selection snapshot must contain 36 entries") unless @snapshot.fetch(:entries).length == 36
      raise DataError.new("Ruby selection snapshot must contain Top 5") unless @snapshot.fetch(:quality_top_n) == 5
    end

    def deterministic_seed(base_seed, entry_id, scenario, strategy)
      Zlib.crc32([base_seed, entry_id, scenario, strategy].join(":"))
    end

    def silence_reason(after_grounding, pool)
      return nil unless pool.empty?
      return "all_candidates_filtered" if after_grounding.empty?

      "strategy_quality_condition_unmet"
    end

    def signature(row)
      row.values_at(:entry_id, :strategy, :scenario, :seed, :selected_line_id, :outcome, :silence_reason)
    end

    def build_output_dir
      timestamp = @now.call.strftime("%Y%m%dT%H%M%SZ")
      File.join(@configuration.path(:results), "ruby_selection_#{timestamp}_#{SecureRandom.hex(2)}")
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
  end
end
