# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"

module AiLineSelection
  class MeaningReviewer
    EVALUATION_FILENAME = "interactive_human_evaluation.csv"
    SUMMARY_FILENAME = "interactive_human_evaluation_summary.json"
    REQUIRED_SOURCE_FILES = %w[human_evaluation.csv blind_mapping.csv].freeze
    STATE_HEADERS = %w[
      entry_id blind_id_a blind_id_b usability_a usability_b
      diagnosis_a diagnosis_b fixed_a fixed_b proper_noun_a proper_noun_b notes
    ].freeze
    FLAG_KEYS = {
      "d" => "diagnosis",
      "f" => "fixed",
      "p" => "proper_noun"
    }.freeze

    def initialize(configuration:, results_dir:, input: $stdin, output: $stdout)
      @configuration = configuration
      @results_dir = File.expand_path(results_dir)
      @input = input
      @output = output
      @evaluation_path = File.join(@results_dir, EVALUATION_FILENAME)
      @summary_path = File.join(@results_dir, SUMMARY_FILENAME)
    end

    def call
      validate_sources!
      source_rows = load_csv("human_evaluation.csv")
      mapping_rows = load_csv("blind_mapping.csv")
      pairs = build_pairs(source_rows, mapping_rows)
      state = load_or_initialize_state(pairs)
      pending_pairs = pairs.reject { |pair| completed?(state.fetch(pair.fetch(:entry_id))) }

      if pending_pairs.empty?
        return complete(state, mapping_rows)
      end

      print_intro(state, pairs.length)
      pending_pairs.each do |pair|
        row = state.fetch(pair.fetch(:entry_id))
        result = review_pair(pair, row, completed_count(state), pairs.length)
        if result == :quit
          save_state(state)
          return paused_result(state, pairs.length)
        end

        save_state(state)
      end

      complete(state, mapping_rows)
    end

    private

    def validate_sources!
      missing = REQUIRED_SOURCE_FILES.reject { |filename| File.file?(File.join(@results_dir, filename)) }
      return if missing.empty?

      raise DataError.new(
        "Meaning comparison artifacts are missing",
        details: { results_dir: @results_dir, missing: missing }
      )
    end

    def load_csv(filename)
      CSV.read(File.join(@results_dir, filename), headers: true, encoding: "bom|utf-8").map(&:to_h)
    rescue CSV::MalformedCSVError => e
      raise DataError.new(
        "Meaning comparison CSV is invalid",
        details: { filename: filename, error_class: e.class.name }
      )
    end

    def build_pairs(source_rows, mapping_rows)
      source_by_blind_id = source_rows.to_h { |row| [row.fetch("blind_id"), row] }
      mappings = mapping_rows.group_by { |row| row.fetch("entry_id") }
      providers = @configuration.meaning_provider_names.sort
      unless providers.length == 2
        raise ConfigurationError.new(
          "Interactive Meaning review requires exactly two providers",
          details: { provider_count: providers.length }
        )
      end

      mappings.keys.sort.map do |entry_id|
        selected = providers.map do |provider|
          candidates = mappings.fetch(entry_id).select { |row| row.fetch("provider") == provider }
          mapping = candidates.min_by { |row| Integer(row.fetch("repetition")) }
          unless mapping
            raise DataError.new(
              "Blind mapping has no output for a configured provider",
              details: { entry_id: entry_id, provider: provider }
            )
          end
          source_by_blind_id.fetch(mapping.fetch("blind_id")) do
            raise DataError.new(
              "Human evaluation artifact has no matching Blind ID",
              details: { blind_id: mapping.fetch("blind_id") }
            )
          end
        end
        selected.reverse! if reverse_sides?(entry_id)
        {
          entry_id: entry_id,
          entry_body: selected.first.fetch("entry_body"),
          a: selected.fetch(0),
          b: selected.fetch(1)
        }
      end
    end

    def reverse_sides?(entry_id)
      digest = Digest::SHA256.hexdigest("#{@configuration.random_seed}:#{entry_id}:interactive-review")
      digest.to_i(16).odd?
    end

    def load_or_initialize_state(pairs)
      state = if File.file?(@evaluation_path)
                load_csv(EVALUATION_FILENAME).to_h { |row| [row.fetch("entry_id"), row] }
              else
                pairs.to_h do |pair|
                  [
                    pair.fetch(:entry_id),
                    STATE_HEADERS.to_h { |header| [header, nil] }.merge(
                      "entry_id" => pair.fetch(:entry_id),
                      "blind_id_a" => pair.dig(:a, "blind_id"),
                      "blind_id_b" => pair.dig(:b, "blind_id")
                    )
                  ]
                end
              end
      validate_state!(state, pairs)
      save_state(state) unless File.file?(@evaluation_path)
      state
    end

    def validate_state!(state, pairs)
      expected = pairs.to_h { |pair| [pair.fetch(:entry_id), [pair.dig(:a, "blind_id"), pair.dig(:b, "blind_id")]] }
      actual = state.transform_values { |row| [row["blind_id_a"], row["blind_id_b"]] }
      return if actual == expected

      raise DataError.new(
        "Saved interactive evaluation does not match the comparison artifacts",
        details: { evaluation_file: @evaluation_path }
      )
    end

    def print_intro(state, total)
      @output.puts <<~TEXT

        Meaning Structure 対話型Blind評価
        - Provider名は全#{total}件の評価完了まで表示しません。
        - 各Providerの第1反復を代表例として評価し、残りは自動の再現性評価に使います。
        - 各回答は1件ごとに保存され、次回は続きから再開します。
        - 途中終了する場合は、入力時に /q を指定してください。

        完了: #{completed_count(state)} / #{total}
      TEXT
    end

    def review_pair(pair, state_row, completed, total)
      @output.puts("\n#{"=" * 72}")
      @output.puts("[#{completed + 1} / #{total}] Entry #{pair.fetch(:entry_id)}")
      @output.puts("\n日記:\n#{pair.fetch(:entry_body)}")
      print_candidate("A", pair.fetch(:a))
      print_candidate("B", pair.fetch(:b))

      usability_a = prompt_choice("Aの利用可能性 [1=困難 / 2=条件付き / 3=利用可能]: ", %w[1 2 3])
      return :quit if usability_a == :quit
      usability_b = prompt_choice("Bの利用可能性 [1=困難 / 2=条件付き / 3=利用可能]: ", %w[1 2 3])
      return :quit if usability_b == :quit
      targets = prompt_choice("問題のある候補 [Enter=none / a / b / both]: ", %w[none a b both], default: "none")
      return :quit if targets == :quit

      flags = empty_flags
      target_sides(targets).each do |side|
        selected = prompt_flags("#{side.upcase}の問題 [d=診断 / f=感情・人物像固定 / p=固有名詞、複数可]: ")
        return :quit if selected == :quit
        selected.each { |flag| flags["#{FLAG_KEYS.fetch(flag)}_#{side}"] = "true" }
      end

      notes = prompt_text("メモ [省略可]: ")
      return :quit if notes == :quit

      state_row.merge!(
        "usability_a" => usability_a,
        "usability_b" => usability_b,
        "diagnosis_a" => flags.fetch("diagnosis_a"),
        "diagnosis_b" => flags.fetch("diagnosis_b"),
        "fixed_a" => flags.fetch("fixed_a"),
        "fixed_b" => flags.fetch("fixed_b"),
        "proper_noun_a" => flags.fetch("proper_noun_a"),
        "proper_noun_b" => flags.fetch("proper_noun_b"),
        "notes" => notes
      )
      @output.puts("保存しました。")
      :saved
    end

    def print_candidate(label, row)
      themes = JSON.parse(row.fetch("themes"))
      @output.puts <<~TEXT

        候補#{label}:
          themes: #{themes.join(" / ")}
          structure: #{row.fetch("structure")}
          abstraction: #{row.fetch("abstraction")}
      TEXT
    rescue JSON::ParserError
      raise DataError.new(
        "Human evaluation artifact contains invalid themes JSON",
        details: { blind_id: row.fetch("blind_id") }
      )
    end

    def prompt_choice(prompt, allowed, default: nil)
      loop do
        value = prompt_text(prompt)
        return :quit if value == :quit
        normalized = value.downcase
        normalized = default if normalized.empty? && default
        return normalized if allowed.include?(normalized)

        @output.puts("入力が正しくありません: #{allowed.join(" / ")}")
      end
    end

    def prompt_flags(prompt)
      loop do
        value = prompt_text(prompt)
        return :quit if value == :quit
        normalized = value.downcase.gsub(/[\s,\/]+/, "")
        normalized = "dfp" if normalized == "all"
        flags = normalized.chars.uniq
        return flags if !flags.empty? && (flags - FLAG_KEYS.keys).empty?

        @output.puts("d、f、pを組み合わせて入力してください（例: d,p）。")
      end
    end

    def prompt_text(prompt)
      @output.print(prompt)
      @output.flush if @output.respond_to?(:flush)
      value = @input.gets
      return :quit if value.nil?

      value = value.chomp
      return :quit if value.strip.downcase == "/q"

      value
    end

    def target_sides(targets)
      case targets
      when "a" then %w[a]
      when "b" then %w[b]
      when "both" then %w[a b]
      else []
      end
    end

    def empty_flags
      %w[diagnosis fixed proper_noun].product(%w[a b]).to_h do |flag, side|
        ["#{flag}_#{side}", "false"]
      end
    end

    def completed?(row)
      %w[usability_a usability_b].all? { |key| %w[1 2 3].include?(row[key]) }
    end

    def completed_count(state)
      state.values.count { |row| completed?(row) }
    end

    def save_state(state)
      FileUtils.mkdir_p(@results_dir)
      CSV.open(@evaluation_path, "w:UTF-8", write_headers: true, headers: STATE_HEADERS) do |csv|
        state.keys.sort.each { |entry_id| csv << state.fetch(entry_id).values_at(*STATE_HEADERS) }
      end
    end

    def paused_result(state, total)
      result = {
        status: "paused",
        completed: completed_count(state),
        total: total,
        evaluation_file: @evaluation_path
      }
      @output.puts("\n評価を保存して終了しました（#{result.fetch(:completed)} / #{total}）。")
      result
    end

    def complete(state, mapping_rows)
      summary = build_summary(state, mapping_rows)
      File.write(@summary_path, JSON.pretty_generate(summary), mode: "w:UTF-8")
      @output.puts("\n全評価が完了しました。ここからProvider名を開示します。")
      @output.puts(JSON.pretty_generate(summary))
      summary
    end

    def build_summary(state, mapping_rows)
      provider_by_blind_id = mapping_rows.to_h { |row| [row.fetch("blind_id"), row.fetch("provider")] }
      evaluations = state.values.flat_map do |row|
        %w[a b].map do |side|
          blind_id = row.fetch("blind_id_#{side}")
          {
            entry_id: row.fetch("entry_id"),
            provider: provider_by_blind_id.fetch(blind_id),
            usability: Integer(row.fetch("usability_#{side}")),
            diagnosis: row.fetch("diagnosis_#{side}") == "true",
            fixed: row.fetch("fixed_#{side}") == "true",
            proper_noun: row.fetch("proper_noun_#{side}") == "true"
          }
        end
      end
      provider_summaries = evaluations.group_by { |item| item.fetch(:provider) }.transform_values do |items|
        usable = items.count { |item| item.fetch(:usability) >= 2 }
        distribution = (1..3).to_h { |score| [score.to_s, items.count { |item| item.fetch(:usability) == score }] }
        {
          evaluated_entries: items.length,
          usability_average: average(items.sum { |item| item.fetch(:usability) }, items.length),
          usability_distribution: distribution,
          usability_two_or_higher_rate: ratio(usable, items.length),
          diagnosis_count: items.count { |item| item.fetch(:diagnosis) },
          fixed_emotion_or_personality_count: items.count { |item| item.fetch(:fixed) },
          unnecessary_proper_noun_count: items.count { |item| item.fetch(:proper_noun) },
          meets_usability_target: ratio(usable, items.length) >= 0.85,
          meets_zero_red_flag_target: items.none? do |item|
            item.fetch(:diagnosis) || item.fetch(:fixed) || item.fetch(:proper_noun)
          end
        }
      end

      {
        status: "complete",
        methodology: {
          entry_count: state.length,
          evaluated_outputs: evaluations.length,
          representative_repetition: 1,
          provider_names_hidden_until_completion: true,
          remaining_repetitions_used_for_automatic_stability_metrics: true
        },
        providers: provider_summaries,
        pairwise_usability: pairwise_summary(evaluations),
        automatic_winner_selected: false,
        evaluation_file: @evaluation_path,
        summary_file: @summary_path
      }
    end

    def pairwise_summary(evaluations)
      wins = Hash.new(0)
      ties = 0
      evaluations.group_by { |item| item.fetch(:entry_id) }.each_value do |items|
        left, right = items
        if left.fetch(:usability) == right.fetch(:usability)
          ties += 1
        else
          winner = [left, right].max_by { |item| item.fetch(:usability) }
          wins[winner.fetch(:provider)] += 1
        end
      end
      { wins: wins.sort.to_h, ties: ties }
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count)
      return 0.0 if count.zero?

      (total.to_f / count).round(4)
    end
  end
end
