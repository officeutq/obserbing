# frozen_string_literal: true

module AiLineSelection
  class PromptRegistry
    FILES = {
      safety: "safety.md",
      meaning: "meaning.md",
      line_evaluation: "line_evaluation.md"
    }.freeze

    def initialize(root_dir: AiLineSelection::ROOT)
      @root_dir = root_dir
      @cache = {}
    end

    def fetch(operation)
      return nil unless FILES.key?(operation.to_sym)

      @cache[operation.to_sym] ||= File.read(
        File.join(@root_dir, "prompts", FILES.fetch(operation.to_sym)),
        encoding: "UTF-8"
      )
    end

    def operations
      FILES.keys
    end
  end
end
