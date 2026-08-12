# frozen_string_literal: true

require "minitest/autorun"
require "json"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ai_line_selection"

module TestSupport
  def configuration
    @configuration ||= AiLineSelection::Configuration.load
  end

  def data_loader
    @data_loader ||= AiLineSelection::DataLoader.new(configuration)
  end
end

class Minitest::Test
  include TestSupport
end

class FakeTransport
  attr_reader :requests

  def initialize(*responses)
    @responses = responses.flatten
    @requests = []
  end

  def post(**request)
    @requests << request
    response = @responses.shift
    raise "No fake response configured" unless response
    raise response if response.is_a?(Exception)

    response
  end
end

module ExternalTestSupport
  def valid_meaning
    {
      "schema_version" => "draft-1",
      "themes" => ["選択"],
      "structure" => "選択の前にためらいがある",
      "abstraction" => "決定と可能性"
    }
  end

  def valid_safety(classification: "normal", reason_code: nil, confidence: 0.98)
    reason_code ||= {
      "normal" => "none",
      "safety" => "suicide_imminent",
      "indeterminate" => "insufficient_context"
    }.fetch(classification)
    {
      "schema_version" => "draft-1",
      "classification" => classification,
      "reason_code" => reason_code,
      "confidence" => confidence
    }
  end

  def valid_line_evaluation
    {
      "schema_version" => "draft-1",
      "recommended_line_id" => "L001",
      "candidates" => %w[L001 L002].map do |line_id|
        {
          "line_id" => line_id,
          "relevance" => 0.8,
          "directness" => 0.4,
          "space" => 0.7,
          "obserbing_fit" => 0.85
        }
      end
    }
  end

  def openai_response(meaning: valid_meaning, status: 200, model: "gpt-5.6-terra", body: nil)
    document = {
      "id" => "resp_test",
      "status" => "completed",
      "model" => model,
      "output" => [
        {
          "type" => "message",
          "content" => [{ "type" => "output_text", "text" => JSON.generate(meaning) }]
        }
      ],
      "usage" => {
        "input_tokens" => 100,
        "output_tokens" => 50,
        "input_tokens_details" => { "cached_tokens" => 20 }
      }
    }
    AiLineSelection::HttpResponse.new(
      status: status,
      headers: { "x-request-id" => "req_test" },
      body: body || JSON.generate(document)
    )
  end

  def anthropic_response(meaning: valid_meaning, status: 200, model: "claude-sonnet-5", body: nil)
    document = {
      "id" => "msg_test",
      "model" => model,
      "stop_reason" => "end_turn",
      "content" => [{ "type" => "text", "text" => JSON.generate(meaning) }],
      "usage" => { "input_tokens" => 90, "output_tokens" => 40 }
    }
    AiLineSelection::HttpResponse.new(
      status: status,
      headers: { "request-id" => "req_anthropic" },
      body: body || JSON.generate(document)
    )
  end

  def openai_embedding_response(count:, dimensions: 8, status: 200, model: "text-embedding-3-small", body: nil)
    document = {
      "object" => "list",
      "data" => count.times.map do |index|
        values = Array.new(dimensions, 0.0)
        values[index % dimensions] = 1.0
        { "object" => "embedding", "index" => index, "embedding" => values }
      end.reverse,
      "model" => model,
      "usage" => { "prompt_tokens" => count * 3, "total_tokens" => count * 3 }
    }
    AiLineSelection::HttpResponse.new(
      status: status,
      headers: { "x-request-id" => "req_embedding" },
      body: body || JSON.generate(document)
    )
  end

  def http_error(status)
    AiLineSelection::HttpResponse.new(
      status: status,
      headers: { "x-request-id" => "req_error", "retry-after" => "0" },
      body: JSON.generate("error" => { "type" => "test" })
    )
  end

  def external_client(provider:, transport:)
    telemetry = AiLineSelection::Telemetry.new(correlation_id: "test", path: nil)
    client = AiLineSelection::OperationClient.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new,
      telemetry: telemetry,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai", "ANTHROPIC_API_KEY" => "test-anthropic" },
      transport: transport,
      sleeper: ->(_seconds) {}
    )
    [client, telemetry, configuration.meaning_provider(provider)]
  end

  def external_embedding_client(provider:, transport:)
    telemetry = AiLineSelection::Telemetry.new(correlation_id: "test", path: nil)
    client = AiLineSelection::OperationClient.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new,
      telemetry: telemetry,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai" },
      transport: transport,
      sleeper: ->(_seconds) {}
    )
    settings = configuration.embedding_provider(provider).merge("dimensions" => 8)
    [client, telemetry, settings]
  end

  def external_safety_client(provider:, transport:)
    telemetry = AiLineSelection::Telemetry.new(correlation_id: "test", path: nil)
    client = AiLineSelection::OperationClient.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new,
      telemetry: telemetry,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai", "ANTHROPIC_API_KEY" => "test-anthropic" },
      transport: transport,
      sleeper: ->(_seconds) {}
    )
    [client, telemetry, configuration.safety_provider(provider)]
  end

  def external_line_evaluation_client(provider:, transport:)
    telemetry = AiLineSelection::Telemetry.new(correlation_id: "test", path: nil)
    client = AiLineSelection::OperationClient.new(
      configuration: configuration,
      schemas: AiLineSelection::SchemaRegistry.new,
      prompts: AiLineSelection::PromptRegistry.new,
      telemetry: telemetry,
      allow_external_api: true,
      environment: { "OPENAI_API_KEY" => "test-openai", "ANTHROPIC_API_KEY" => "test-anthropic" },
      transport: transport,
      sleeper: ->(_seconds) {}
    )
    [client, telemetry, configuration.line_evaluation_provider(provider)]
  end

  def line_evaluation_input
    {
      "meaning" => { "themes" => ["test"], "structure" => "test", "abstraction" => "test" },
      "candidates" => [
        { "line" => { "id" => "L001", "text" => "first" }, "similarity" => 0.8 },
        { "line" => { "id" => "L002", "text" => "second" }, "similarity" => 0.7 }
      ]
    }
  end
end

class Minitest::Test
  include ExternalTestSupport
end
