# frozen_string_literal: true

require_relative "test_helper"

class LineEvaluationContractTest < Minitest::Test
  class StaticAdapter
    def initialize(data)
      @data = data
    end

    def call(request)
      AiLineSelection::AdapterResponse.new(
        data: @data,
        provider: "test",
        model: request.model,
        request_id: "test-line-evaluation",
        usage: AiLineSelection::Usage.zero
      )
    end
  end

  def test_missing_candidate_id_is_a_technical_error_not_silence
    data = valid_output.fetch("candidates").first(1)
    error = assert_raises(AiLineSelection::ProviderContractError) do
      client(data: valid_output.merge("candidates" => data)).call(:line_evaluation, input)
    end

    assert_equal ["L002"], error.details.fetch(:missing_ids)
    refute_equal "no_qualified_candidate", error.code
  end

  def test_unknown_recommendation_is_rejected
    error = assert_raises(AiLineSelection::ProviderContractError) do
      client(data: valid_output.merge("recommended_line_id" => "L999")).call(:line_evaluation, input)
    end

    assert_equal "L999", error.details.fetch(:invalid_recommendation)
  end

  def test_duplicate_and_unknown_candidate_ids_are_rejected
    candidates = valid_output.fetch("candidates")
    invalid = valid_output.merge(
      "candidates" => [candidates.first, candidates.first, candidates.last.merge("line_id" => "L999")]
    )

    error = assert_raises(AiLineSelection::ProviderContractError) do
      client(data: invalid).call(:line_evaluation, input)
    end

    assert_equal ["L001"], error.details.fetch(:duplicate_ids)
    assert_equal ["L999"], error.details.fetch(:unknown_ids)
  end

  def test_numeric_range_violation_is_rejected_before_selection
    candidate = valid_output.fetch("candidates").first.merge("space" => 1.01)
    invalid = valid_output.merge("candidates" => [candidate, valid_output.fetch("candidates").last])

    error = assert_raises(AiLineSelection::SchemaValidationError) do
      client(data: invalid).call(:line_evaluation, input)
    end

    assert_includes error.details.fetch(:errors), "$.candidates[0].space: must be between 0 and 1"
  end

  def test_valid_silence_is_semantic_result
    invocation = client(data: valid_output.merge("recommended_line_id" => "SILENCE")).call(:line_evaluation, input)

    assert_equal "SILENCE", invocation.value.fetch("recommended_line_id")
  end

  private

  def input
    {
      "meaning" => { "themes" => ["test"], "structure" => "test", "abstraction" => "test" },
      "candidates" => [
        { "line" => { "id" => "L001", "text" => "first" }, "similarity" => 0.8 },
        { "line" => { "id" => "L002", "text" => "second" }, "similarity" => 0.7 }
      ]
    }
  end

  def valid_output
    {
      "schema_version" => "draft-1",
      "recommended_line_id" => "L001",
      "candidates" => %w[L001 L002].map do |id|
        {
          "line_id" => id,
          "relevance" => 0.8,
          "directness" => 0.4,
          "space" => 0.7,
          "obserbing_fit" => 0.8
        }
      end
    }
  end

  def client(data:)
    AiLineSelection::OperationClient.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new,
      telemetry: AiLineSelection::Telemetry.new(correlation_id: "line-contract", path: nil),
      adapter_override: StaticAdapter.new(data)
    )
  end
end
