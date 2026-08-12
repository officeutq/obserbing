# frozen_string_literal: true

module AiLineSelection
  class FinalSelector
    def initialize(settings)
      @settings = settings
    end

    def select(evaluations, allowed_lines)
      lines_by_id = allowed_lines.to_h { |line| [line.fetch("id"), line] }
      qualified = evaluations.filter_map do |evaluation|
        line = lines_by_id[evaluation.fetch("line_id")]
        next unless line
        next unless qualified?(evaluation)

        { line: line, evaluation: evaluation, final_score: final_score(evaluation) }
      end

      winner = qualified.max_by { |item| [item.fetch(:final_score), item.fetch(:line).fetch("id")] }
      return silence("no_qualified_candidate") unless winner

      {
        status: "line",
        line_id: winner.fetch(:line).fetch("id"),
        line_text: winner.fetch(:line).fetch("text"),
        final_score: winner.fetch(:final_score),
        silence_reason: nil
      }
    end

    private

    def qualified?(evaluation)
      evaluation.fetch("relevance") >= @settings.fetch("minimum_relevance") &&
        evaluation.fetch("directness") <= @settings.fetch("maximum_directness") &&
        evaluation.fetch("space") >= @settings.fetch("minimum_space") &&
        evaluation.fetch("obserbing_fit") >= @settings.fetch("minimum_obserbing_fit")
    end

    def final_score(evaluation)
      directness_fit = 1.0 - (evaluation.fetch("directness") - 0.35).abs
      score = (evaluation.fetch("relevance") * 0.35) +
              (directness_fit * 0.15) +
              (evaluation.fetch("space") * 0.25) +
              (evaluation.fetch("obserbing_fit") * 0.25)
      score.round(4)
    end

    def silence(reason)
      {
        status: "silence",
        line_id: nil,
        line_text: nil,
        final_score: nil,
        silence_reason: reason
      }
    end
  end
end
