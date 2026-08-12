# frozen_string_literal: true

require "json"

module AiLineSelection
  class EmbeddingTextBuilder
    VERSION = "embedding-text-v1"
    VARIANTS = %w[original meaning_structure normalized_text].freeze

    def entry_text(entry, variant)
      expected = entry.fetch("expected")
      case validate_variant(variant)
      when "original"
        normalize(entry.fetch("body"))
      when "meaning_structure"
        JSON.generate(
          "themes" => expected.fetch("themes"),
          "structure" => expected.fetch("structure"),
          "abstraction" => expected.fetch("abstraction")
        )
      when "normalized_text"
        normalize([
          expected.fetch("themes").join(" "),
          expected.fetch("structure"),
          expected.fetch("abstraction")
        ].join("\n"))
      end
    end

    def line_text(line, variant)
      case validate_variant(variant)
      when "original"
        normalize(line.fetch("text"))
      when "meaning_structure"
        JSON.generate(
          "theme" => line.fetch("theme"),
          "meaning" => line.fetch("meaning")
        )
      when "normalized_text"
        normalize([
          line.fetch("theme"),
          line.fetch("meaning"),
          line.fetch("text")
        ].join("\n"))
      end
    end

    private

    def validate_variant(variant)
      value = variant.to_s
      return value if VARIANTS.include?(value)

      raise ConfigurationError.new(
        "Unknown Embedding text variant",
        details: { variant: value, allowed: VARIANTS }
      )
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
    end
  end
end
