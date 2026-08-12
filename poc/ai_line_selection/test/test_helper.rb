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
end

class Minitest::Test
  include ExternalTestSupport
end
