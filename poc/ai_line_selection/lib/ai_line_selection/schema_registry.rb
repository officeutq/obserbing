# frozen_string_literal: true

require "json"

module AiLineSelection
  class SchemaRegistry
    FILES = {
      safety: "safety.json",
      meaning: "meaning.json",
      abstraction: "abstraction.json",
      embedding: "embedding.json",
      line_evaluation: "line_evaluation.json",
      candidate_quality: "candidate_quality.json"
    }.freeze

    def initialize(root_dir: AiLineSelection::ROOT, files: {})
      @root_dir = root_dir
      @files = FILES.merge(files.transform_keys(&:to_sym))
      @cache = {}
    end

    def fetch(operation)
      @cache[operation.to_sym] ||= begin
        filename = @files.fetch(operation.to_sym)
        JSON.parse(File.read(File.join(@root_dir, "schemas", filename), encoding: "UTF-8"))
      end
    rescue KeyError
      raise ConfigurationError.new("No schema registered", details: { operation: operation.to_s })
    rescue JSON::ParserError
      raise ConfigurationError.new("Registered schema is invalid JSON", details: { operation: operation.to_s })
    end

    def operations
      @files.keys
    end
  end
end
