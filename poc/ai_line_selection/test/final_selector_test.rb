# frozen_string_literal: true

require_relative "test_helper"

class FinalSelectorTest < Minitest::Test
  def setup
    @selector = AiLineSelection::FinalSelector.new(configuration.selection.fetch("policies").fetch("balanced"))
    @line = { "id" => "L001", "text" => "test" }
  end

  def test_no_qualified_candidate_is_semantic_silence
    result = @selector.explain(
      [evaluation("directness" => 0.9, "space" => 0.2)],
      [@line]
    )

    assert_equal "silence", result.fetch(:status)
    assert_equal "no_qualified_candidate", result.fetch(:silence_reason)
    assert_equal %w[directness space], result.dig(:rejections, "L001")
  end

  def test_qualified_candidate_is_returned
    result = @selector.select([evaluation], [@line])

    assert_equal "line", result.fetch(:status)
    assert_equal "L001", result.fetch(:line_id)
  end

  private

  def evaluation(overrides = {})
    {
      "line_id" => "L001",
      "relevance" => 0.8,
      "directness" => 0.4,
      "space" => 0.7,
      "obserbing_fit" => 0.85
    }.merge(overrides)
  end
end
