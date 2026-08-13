# frozen_string_literal: true

module AiLineSelection
  class PromptRegistry
    FILES = {
      safety: "safety.md",
      meaning: "meaning.md",
      line_evaluation: "line_evaluation.md"
    }.freeze

    def initialize(root_dir: AiLineSelection::ROOT, files: {})
      @root_dir = root_dir
      @files = FILES.merge(files.transform_keys(&:to_sym))
      @cache = {}
    end

    def fetch(operation)
      return nil unless @files.key?(operation.to_sym)

      @cache[operation.to_sym] ||= File.read(
        File.join(@root_dir, "prompts", @files.fetch(operation.to_sym)),
        encoding: "UTF-8"
      )
    end

    def operations
      @files.keys
    end
  end
end
