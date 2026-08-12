# frozen_string_literal: true

require "securerandom"

module AiLineSelection
  class Runner
    attr_reader :telemetry

    def initialize(configuration:, data_loader: nil, adapter_override: nil, telemetry_path: :configured)
      @configuration = configuration
      @data_loader = data_loader || DataLoader.new(configuration)
      @schemas = SchemaRegistry.new(root_dir: configuration.root_dir)
      @prompts = PromptRegistry.new(root_dir: configuration.root_dir)
      @correlation_id = SecureRandom.uuid
      path = telemetry_path == :configured ? configuration.path(:telemetry) : telemetry_path
      @telemetry = Telemetry.new(correlation_id: @correlation_id, path: path)
      @client = OperationClient.new(
        configuration: configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: @telemetry,
        adapter_override: adapter_override
      )
    end

    def run(entry_id:)
      run_entry(@data_loader.entry(entry_id))
    end

    def classify_safety(entry)
      @client.call(
        :safety,
        { "entry_text" => entry.fetch("body") },
        fixture_context: { "expected" => entry.fetch("expected") }
      ).value
    end

    def run_entry(entry)
      safety = classify_safety(entry)
      case safety.fetch("classification")
      when "safety"
        return safety_result(entry, safety)
      when "indeterminate"
        raise SafetyIndeterminateError
      end

      meaning = @client.call(
        :meaning,
        { "entry_text" => entry.fetch("body") },
        fixture_context: { "expected" => entry.fetch("expected") }
      ).value
      approved_lines = @data_loader.lines.select { |line| line.fetch("status") == "approved" }
      search_text = [meaning.fetch("themes").join(" "), meaning.fetch("structure"), meaning.fetch("abstraction")].join("\n")
      texts = [search_text] + approved_lines.map do |line|
        [line.fetch("theme"), line.fetch("meaning"), line.fetch("text")].join(" ")
      end
      embedding = @client.call(:embedding, { "texts" => texts }).value
      vectors = embedding.fetch("vectors").map { |item| item.fetch("values") }

      candidates = CandidateSearch.new.search(
        query_vector: vectors.first,
        lines: approved_lines,
        line_vectors: vectors.drop(1),
        limit: @configuration.search.fetch("candidate_limit")
      )
      evaluation_candidates = candidates.first(@configuration.search.fetch("evaluation_limit"))
      telemetry.record(candidate_count: evaluation_candidates.length, status: "candidate_search")

      evaluations = @client.call(
        :line_evaluation,
        {
          "meaning" => meaning,
          "candidates" => evaluation_candidates
        }
      ).value.fetch("candidates")

      selection = FinalSelector.new(@configuration.selection).select(
        evaluations,
        evaluation_candidates.map { |candidate| candidate.fetch("line") }
      )
      evaluation = evaluation_summary(entry, approved_lines, evaluation_candidates, selection)

      {
        entry_id: entry.fetch("id"),
        status: selection.fetch(:status),
        line_id: selection.fetch(:line_id),
        line_text: selection.fetch(:line_text),
        final_score: selection.fetch(:final_score),
        silence_reason: selection.fetch(:silence_reason),
        candidate_count: evaluation_candidates.length,
        evaluation: evaluation,
        telemetry: telemetry.summary
      }
    end

    private

    def safety_result(entry, safety)
      {
        entry_id: entry.fetch("id"),
        status: "safety",
        safety_response_id: "SAFETY_COPY_TBD",
        safety_reason_code: safety.fetch("reason_code"),
        telemetry: telemetry.summary
      }
    end

    def evaluation_summary(entry, approved_lines, candidates, selection)
      expected_themes = entry.fetch("expected").fetch("themes")
      relevant_ids = approved_lines.filter_map do |line|
        line.fetch("id") if expected_themes.include?(line.fetch("theme"))
      end
      candidate_ids = candidates.map { |candidate| candidate.fetch("line").fetch("id") }
      recall = if relevant_ids.empty?
                 nil
               else
                 ((candidate_ids & relevant_ids).length.to_f / relevant_ids.length).round(4)
               end
      selected_line = approved_lines.find { |line| line.fetch("id") == selection.fetch(:line_id) }

      {
        expected_themes: expected_themes,
        relevant_line_count: relevant_ids.length,
        candidate_recall: recall,
        selected_theme_match: selected_line ? expected_themes.include?(selected_line.fetch("theme")) : nil
      }
    end
  end
end
