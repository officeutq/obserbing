# frozen_string_literal: true

require "csv"
require "json"

module AiLineSelection
  class LineEvaluationReviewer
    EVALUATION_FILENAME = "human_evaluation.csv"
    MAPPING_FILENAME = "blind_mapping.csv"
    SUMMARY_FILENAME = "human_evaluation_summary.json"
    DISTANCES = %w[too_close just_right too_far not_obserbing].freeze

    def initialize(configuration:, results_dir:, input: $stdin, output: $stdout)
      @configuration = configuration
      @results_dir = File.expand_path(results_dir)
      @input = input
      @output = output
      @evaluation_path = File.join(@results_dir, EVALUATION_FILENAME)
      @mapping_path = File.join(@results_dir, MAPPING_FILENAME)
      @summary_path = File.join(@results_dir, SUMMARY_FILENAME)
    end

    def call
      rows = load_csv(@evaluation_path)
      mappings = load_csv(@mapping_path)
      validate_rows!(rows, mappings)
      pending = rows.select { |row| needs_human_review?(row) }
      print_intro(rows, pending.length)

      pending.each_with_index do |row, index|
        result = review(row, index + 1, pending.length)
        save(rows)
        return paused(rows) if result == :quit
      end

      incomplete = rows.reject { |row| completed?(row) }
      return awaiting_preliminary(rows, incomplete) unless incomplete.empty?

      complete(rows, mappings)
    end

    private

    def load_csv(path)
      unless File.file?(path)
        raise DataError.new("Line evaluation review artifact is missing", details: { path: path })
      end

      CSV.read(path, headers: true, encoding: "bom|utf-8").map(&:to_h)
    rescue CSV::MalformedCSVError => e
      raise DataError.new("Line evaluation review CSV is invalid", details: { path: path, error_class: e.class.name })
    end

    def validate_rows!(rows, mappings)
      mapping_ids = mappings.map { |row| row.fetch("blind_id") }
      row_ids = rows.map { |row| row.fetch("blind_id") }
      return if row_ids.sort == mapping_ids.sort && row_ids.uniq.length == row_ids.length

      raise DataError.new("Line evaluation review artifacts do not match")
    end

    def print_intro(rows, pending_count)
      @output.puts <<~TEXT

        Line距離の低確信ケース確認
        - Provider名は完了まで表示しません。
        - Codex一次評価で needs_human_review=true の行だけを確認します。
        - c=近すぎる / j=ちょうどいい / f=遠すぎる / n=obserbingらしくない
        - 途中終了は /q です。各回答は直ちに保存されます。

        全出力: #{rows.length} / 今回の確認対象: #{pending_count}
      TEXT
    end

    def review(row, index, total)
      @output.puts("\n#{"=" * 72}")
      @output.puts("[#{index} / #{total}] #{row.fetch("blind_id")}")
      @output.puts("\n日記:\n#{row.fetch("entry_body")}")
      if row.fetch("outcome") == "silence"
        @output.puts("\n選定: SILENCE")
      else
        @output.puts("\n選定Line:\n#{row.fetch("selected_line_text")}")
      end
      unless row["reason"].to_s.empty?
        @output.puts("\nCodex一次評価: #{row.fetch("reason")}")
      end

      distance = choice("距離 [c/j/f/n]: ", "c" => "too_close", "j" => "just_right", "f" => "too_far", "n" => "not_obserbing")
      return :quit if distance == :quit
      acceptable = choice("許容できる [y/n]: ", "y" => "true", "n" => "false")
      return :quit if acceptable == :quit
      fatal = text("致命的違反 [Enter=なし / 短い理由]: ")
      return :quit if fatal == :quit
      notes = text("メモ [Enter=省略]: ")
      return :quit if notes == :quit

      row.merge!(
        "distance_rating" => distance,
        "acceptable" => acceptable,
        "fatal_violation" => fatal.empty? ? "none" : fatal,
        "judge" => "human",
        "confidence" => "human",
        "reason" => notes.empty? ? row["reason"] : notes,
        "needs_human_review" => "false",
        "human_reviewed" => "true",
        "notes" => notes
      )
      @output.puts("保存しました。")
      :saved
    end

    def choice(prompt, mapping)
      loop do
        value = text(prompt)
        return :quit if value == :quit
        result = mapping[value.downcase]
        return result if result

        @output.puts("入力が正しくありません: #{mapping.keys.join(" / ")}")
      end
    end

    def text(prompt)
      @output.print(prompt)
      @output.flush if @output.respond_to?(:flush)
      value = @input.gets
      return :quit if value.nil?

      value = value.chomp
      return :quit if value.strip.downcase == "/q"

      value
    end

    def needs_human_review?(row)
      row["needs_human_review"] == "true"
    end

    def completed?(row)
      DISTANCES.include?(row["distance_rating"]) && %w[true false].include?(row["acceptable"]) &&
        !row["fatal_violation"].to_s.empty? && !row["judge"].to_s.empty? && !row["confidence"].to_s.empty?
    end

    def save(rows)
      headers = rows.first&.keys || []
      CSV.open(@evaluation_path, "w:UTF-8", write_headers: true, headers: headers) do |csv|
        rows.each { |row| csv << row.values_at(*headers) }
      end
    end

    def paused(rows)
      result = {
        status: "paused",
        completed_outputs: rows.count { |row| completed?(row) },
        total_outputs: rows.length,
        evaluation_file: @evaluation_path
      }
      @output.puts("\n確認結果を保存して終了しました。")
      result
    end

    def awaiting_preliminary(rows, incomplete)
      result = {
        status: "awaiting_preliminary_evaluation",
        completed_outputs: rows.length - incomplete.length,
        incomplete_outputs: incomplete.length,
        human_review_pending: incomplete.count { |row| needs_human_review?(row) },
        evaluation_file: @evaluation_path
      }
      @output.puts("\nCodex一次評価が未記入の出力が#{incomplete.length}件あります。")
      result
    end

    def complete(rows, mappings)
      providers = mappings.to_h { |row| [row.fetch("blind_id"), row.fetch("provider")] }
      evaluations = rows.map do |row|
        {
          entry_id: row.fetch("entry_id"),
          provider: providers.fetch(row.fetch("blind_id")),
          distance: row.fetch("distance_rating"),
          acceptable: row.fetch("acceptable") == "true",
          fatal: row.fetch("fatal_violation") != "none",
          judge: row.fetch("judge"),
          human_reviewed: row.fetch("human_reviewed") == "true"
        }
      end
      summary = {
        status: "complete",
        methodology: {
          representative_repetition: 1,
          provider_names_hidden_during_review: true,
          preliminary_and_human_judgments_kept_separate: true,
          low_confidence_only_human_review: true
        },
        judge_counts: evaluations.map { |item| item.fetch(:judge) }.tally.sort.to_h,
        human_reviewed_outputs: evaluations.count { |item| item.fetch(:human_reviewed) },
        providers: evaluations.group_by { |item| item.fetch(:provider) }.transform_values do |items|
          {
            evaluated_outputs: items.length,
            acceptable_rate: ratio(items.count { |item| item.fetch(:acceptable) }, items.length),
            distance_distribution: DISTANCES.to_h { |name| [name, items.count { |item| item.fetch(:distance) == name }] },
            fatal_violation_count: items.count { |item| item.fetch(:fatal) },
            meets_acceptable_target: ratio(items.count { |item| item.fetch(:acceptable) }, items.length) >= 0.80,
            meets_zero_fatal_target: items.none? { |item| item.fetch(:fatal) }
          }
        end,
        evaluation_file: @evaluation_path,
        summary_file: @summary_path
      }
      File.write(@summary_path, JSON.pretty_generate(summary), mode: "w:UTF-8")
      update_comparison_summary(summary)
      @output.puts("\n全評価が完了しました。Provider別集計を開示します。")
      @output.puts(JSON.pretty_generate(summary))
      summary
    end

    def update_comparison_summary(review_summary)
      path = File.join(@results_dir, "summary.json")
      return unless File.file?(path)

      summary = JSON.parse(File.read(path, encoding: "UTF-8"))
      summary["human_evaluation"] = {
        "status" => "complete",
        "judge_counts" => review_summary.fetch(:judge_counts),
        "human_reviewed_outputs" => review_summary.fetch(:human_reviewed_outputs),
        "summary_file" => @summary_path
      }
      update_adoption_criteria(summary, review_summary)
      File.write(path, JSON.pretty_generate(summary), mode: "w:UTF-8")
    rescue JSON::ParserError => e
      raise DataError.new("Line evaluation comparison summary is invalid JSON", details: { error_class: e.class.name })
    end

    def update_adoption_criteria(summary, review_summary)
      criteria = summary["adoption_criteria"]
      return unless criteria.is_a?(Hash)

      provider_results = review_summary.fetch(:providers).values
      criteria["final_quality_decision_pending_human_evaluation"] = false
      criteria["human_acceptable_at_least_80_percent"] = provider_results.all? do |result|
        result.fetch(:meets_acceptable_target)
      end
      criteria["human_zero_fatal_violations"] = provider_results.all? do |result|
        result.fetch(:meets_zero_fatal_target)
      end
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end
  end
end
