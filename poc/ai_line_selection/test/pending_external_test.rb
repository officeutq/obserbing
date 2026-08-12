# frozen_string_literal: true

require_relative "test_helper"

class PendingExternalTest < Minitest::Test
  def test_stops_before_network_when_external_api_is_disabled
    request = AiLineSelection::RequestBuilder.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new
    ).build(:safety, { "entry_text" => data_loader.entry("E001").fetch("body") })

    error = assert_raises(AiLineSelection::ExternalApiDisabledError) do
      AiLineSelection::Adapters::PendingExternal.new(configuration: configuration).call(request)
    end

    assert_equal "external_api_disabled", error.code
  end

  def test_pending_adapter_contains_no_network_client
    source = File.read(
      File.join(AiLineSelection::ROOT, "lib", "ai_line_selection", "adapters", "pending_external.rb"),
      encoding: "UTF-8"
    )

    refute_match(/Net::HTTP|Faraday|HTTParty|HTTP\.rb|OpenAI/, source)
  end
end
