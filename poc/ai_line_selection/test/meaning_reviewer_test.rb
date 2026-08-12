# frozen_string_literal: true

require "csv"
require "json"
require "stringio"
require "tmpdir"
require_relative "test_helper"

class MeaningReviewerTest < Minitest::Test
  def test_pauses_without_revealing_providers_and_resumes_at_next_entry
    Dir.mktmpdir do |directory|
      write_review_artifacts(directory, %w[E001 E002])
      first_output = StringIO.new
      first = reviewer(directory, "3\n2\n\n最初の評価\n/q\n", first_output).call

      assert_equal "paused", first.fetch(:status)
      assert_equal 1, first.fetch(:completed)
      assert File.file?(File.join(directory, "interactive_human_evaluation.csv"))
      refute_includes first_output.string, "openai"
      refute_includes first_output.string, "anthropic"

      second_output = StringIO.new
      completed = reviewer(directory, "2\n3\nnone\n\n", second_output).call

      assert_equal "complete", completed.fetch(:status)
      assert_equal 2, completed.dig(:methodology, :entry_count)
      assert_equal 4, completed.dig(:methodology, :evaluated_outputs)
      assert_includes second_output.string, "[2 / 2]"
      assert_includes second_output.string, "openai"
      assert_includes second_output.string, "anthropic"
      assert File.file?(File.join(directory, "interactive_human_evaluation_summary.json"))
    end
  end

  def test_records_red_flags_only_for_the_selected_side
    Dir.mktmpdir do |directory|
      write_review_artifacts(directory, %w[E001])
      summary = reviewer(directory, "3\n1\na\nd,p\n要確認\n", StringIO.new).call
      totals = summary.fetch(:providers).values

      assert_equal 1, totals.sum { |item| item.fetch(:diagnosis_count) }
      assert_equal 0, totals.sum { |item| item.fetch(:fixed_emotion_or_personality_count) }
      assert_equal 1, totals.sum { |item| item.fetch(:unnecessary_proper_noun_count) }
      assert_equal false, summary.fetch(:automatic_winner_selected)
    end
  end

  private

  def reviewer(directory, input, output)
    AiLineSelection::MeaningReviewer.new(
      configuration: configuration,
      results_dir: directory,
      input: StringIO.new(input),
      output: output
    )
  end

  def write_review_artifacts(directory, entry_ids)
    evaluation_headers = %w[
      blind_id entry_id entry_body themes structure abstraction usability_1_3
      contains_diagnosis unjustified_fixed_emotion_or_personality unnecessary_proper_noun notes
    ]
    mapping_headers = %w[blind_id entry_id repetition provider model request_id]
    evaluation_rows = []
    mapping_rows = []

    entry_ids.each do |entry_id|
      %w[openai anthropic].each do |provider|
        blind_id = "#{entry_id}-#{provider}-1"
        evaluation_rows << [
          blind_id,
          entry_id,
          "#{entry_id}の合成日記",
          JSON.generate(["選択"]),
          "選択とためらいの関係",
          "変化と留保",
          nil, nil, nil, nil, nil
        ]
        mapping_rows << [blind_id, entry_id, 1, provider, "hidden-model", "request-id"]
      end
    end

    CSV.open(
      File.join(directory, "human_evaluation.csv"),
      "w:UTF-8",
      write_headers: true,
      headers: evaluation_headers
    ) { |csv| evaluation_rows.each { |row| csv << row } }
    CSV.open(
      File.join(directory, "blind_mapping.csv"),
      "w:UTF-8",
      write_headers: true,
      headers: mapping_headers
    ) { |csv| mapping_rows.each { |row| csv << row } }
  end
end
