# frozen_string_literal: true

require_relative "test_helper"

class EmbeddingTextBuilderTest < Minitest::Test
  def setup
    @builder = AiLineSelection::EmbeddingTextBuilder.new
    @entry = data_loader.entry("E001")
    @line = data_loader.lines.first
  end

  def test_builds_distinct_entry_variants
    values = AiLineSelection::EmbeddingTextBuilder::VARIANTS.map do |variant|
      @builder.entry_text(@entry, variant)
    end

    assert_equal 3, values.uniq.length
    assert_includes values.fetch(1), '"themes"'
    assert_includes values.fetch(2), "決定と喪失可能性の同居"
  end

  def test_normalized_text_collapses_whitespace_and_unicode_width
    entry = Marshal.load(Marshal.dump(@entry))
    entry["expected"]["structure"] = "Ａ  \n  B"

    text = @builder.entry_text(entry, "normalized_text")

    assert_includes text, "A B"
    refute_includes text, "\n"
  end

  def test_builds_distinct_line_variants
    values = AiLineSelection::EmbeddingTextBuilder::VARIANTS.map do |variant|
      @builder.line_text(@line, variant)
    end

    assert_equal 3, values.uniq.length
    assert_includes values.fetch(1), '"meaning"'
  end

  def test_rejects_unknown_variant
    error = assert_raises(AiLineSelection::ConfigurationError) do
      @builder.entry_text(@entry, "unknown")
    end

    assert_equal "configuration_error", error.code
  end
end
