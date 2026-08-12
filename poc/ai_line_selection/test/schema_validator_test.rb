# frozen_string_literal: true

require_relative "test_helper"

class SchemaValidatorTest < Minitest::Test
  def setup
    @schemas = AiLineSelection::SchemaRegistry.new
    @validator = AiLineSelection::SchemaValidator.new
  end

  def test_accepts_valid_meaning
    value = {
      "schema_version" => "draft-1",
      "themes" => ["選択"],
      "structure" => "選択の前にためらいがある",
      "abstraction" => "選択とためらい"
    }

    assert_same value, @validator.validate!(:meaning, @schemas.fetch(:meaning), value)
  end

  def test_rejects_unknown_fields_and_missing_required_fields
    value = {
      "schema_version" => "draft-1",
      "themes" => [],
      "structure" => "",
      "diagnosis" => "not allowed"
    }

    error = assert_raises(AiLineSelection::SchemaValidationError) do
      @validator.validate!(:meaning, @schemas.fetch(:meaning), value)
    end

    assert_equal "schema_validation_error", error.code
    assert error.details.fetch(:errors).any? { |message| message.include?("diagnosis") }
    assert error.details.fetch(:errors).any? { |message| message.include?("abstraction") }
  end
end
