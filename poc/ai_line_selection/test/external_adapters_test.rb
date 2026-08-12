# frozen_string_literal: true

require_relative "test_helper"

class ExternalAdaptersTest < Minitest::Test
  def test_openai_responses_api_uses_structured_outputs_and_normalizes_usage
    transport = FakeTransport.new(openai_response)
    client, telemetry, settings = external_client(provider: "openai", transport: transport)

    invocation = client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)

    assert_equal valid_meaning, invocation.value
    assert_equal "openai", invocation.metadata.fetch(:provider)
    assert_equal 100, invocation.metadata.dig(:usage, :input_units)
    assert_equal 20, invocation.metadata.dig(:usage, :cached_input_units)
    assert_equal "success", telemetry.events.last.fetch(:status)
    body = JSON.parse(transport.requests.first.fetch(:body))
    assert_equal "low", body.dig("reasoning", "effort")
    assert_equal "json_schema", body.dig("text", "format", "type")
    assert_equal false, body.fetch("store")
    refute body.key?("tools")
  end

  def test_anthropic_messages_api_uses_structured_outputs_and_low_effort
    transport = FakeTransport.new(anthropic_response)
    client, _telemetry, settings = external_client(provider: "anthropic", transport: transport)

    invocation = client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)

    assert_equal valid_meaning, invocation.value
    assert_equal "anthropic", invocation.metadata.fetch(:provider)
    body = JSON.parse(transport.requests.first.fetch(:body))
    assert_equal "low", body.dig("output_config", "effort")
    assert_equal "json_schema", body.dig("output_config", "format", "type")
    refute body.key?("tools")
  end

  def test_openai_safety_uses_structured_output_without_generating_fixed_copy
    safety = valid_safety(classification: "safety")
    transport = FakeTransport.new(openai_response(meaning: safety))
    client, _telemetry, settings = external_safety_client(provider: "openai", transport: transport)

    invocation = client.call(:safety, { "entry_text" => "合成SAFETYケース" }, settings: settings)

    assert_equal "safety", invocation.value.fetch("classification")
    body = JSON.parse(transport.requests.first.fetch(:body))
    assert_equal "safety_classification", body.dig("text", "format", "name")
    assert_equal "合成SAFETYケース", body.fetch("input")
    refute_includes body.to_s, "SAFETY_COPY_TBD"
  end

  def test_anthropic_safety_uses_structured_output
    safety = valid_safety(classification: "indeterminate")
    transport = FakeTransport.new(anthropic_response(meaning: safety))
    client, _telemetry, settings = external_safety_client(provider: "anthropic", transport: transport)

    invocation = client.call(:safety, { "entry_text" => "合成SAFETYケース" }, settings: settings)

    assert_equal "indeterminate", invocation.value.fetch("classification")
    body = JSON.parse(transport.requests.first.fetch(:body))
    assert_equal "合成SAFETYケース", body.dig("messages", 0, "content")
    refute_includes body.to_s, "SAFETY_COPY_TBD"
  end

  def test_safety_contract_retries_out_of_range_confidence
    invalid = valid_safety(confidence: 1.1)
    transport = FakeTransport.new(openai_response(meaning: invalid), openai_response(meaning: valid_safety))
    client, _telemetry, settings = external_safety_client(provider: "openai", transport: transport)

    invocation = client.call(:safety, { "entry_text" => "合成日記" }, settings: settings)

    assert_equal 1, invocation.metadata.fetch(:retry_count)
    assert_equal "schema_validation_error", invocation.metadata.fetch(:attempts).first.fetch(:error_code)
  end

  def test_safety_contract_rejects_reason_inconsistent_with_classification
    invalid = valid_safety(classification: "normal", reason_code: "suicide_imminent")
    transport = FakeTransport.new(openai_response(meaning: invalid), openai_response(meaning: invalid))
    client, _telemetry, settings = external_safety_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::SchemaValidationError) do
      client.call(:safety, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_equal 2, transport.requests.length
  end

  def test_openai_line_evaluation_uses_structured_batch_without_hidden_line_metadata
    transport = FakeTransport.new(openai_response(meaning: valid_line_evaluation))
    client, _telemetry, settings = external_line_evaluation_client(provider: "openai", transport: transport)

    invocation = client.call(:line_evaluation, line_evaluation_input, settings: settings)

    assert_equal "L001", invocation.value.fetch("recommended_line_id")
    body = JSON.parse(transport.requests.first.fetch(:body))
    input = JSON.parse(body.fetch("input"))
    assert_equal 2, input.fetch("candidates").length
    refute_includes body.fetch("input"), "directness"
    assert_equal "line_evaluation", body.dig("text", "format", "name")
  end

  def test_anthropic_line_evaluation_uses_structured_batch
    transport = FakeTransport.new(anthropic_response(meaning: valid_line_evaluation))
    client, _telemetry, settings = external_line_evaluation_client(provider: "anthropic", transport: transport)

    invocation = client.call(:line_evaluation, line_evaluation_input, settings: settings)

    assert_equal "L001", invocation.value.fetch("recommended_line_id")
    body = JSON.parse(transport.requests.first.fetch(:body))
    input = JSON.parse(body.dig("messages", 0, "content"))
    assert_equal %w[L001 L002], input.fetch("candidates").map { |item| item.dig("line", "id") }
  end

  def test_authentication_error_is_not_retried
    transport = FakeTransport.new(http_error(401), openai_response)
    client, telemetry, settings = external_client(provider: "openai", transport: transport)

    error = assert_raises(AiLineSelection::AuthenticationError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end

    assert_equal "authentication_error", error.code
    assert_equal 1, transport.requests.length
    assert_equal "error", telemetry.events.last.fetch(:status)
  end

  def test_non_retryable_http_error_exposes_only_structured_provider_fields
    response = AiLineSelection::HttpResponse.new(
      status: 400,
      headers: { "x-request-id" => "req_bad" },
      body: JSON.generate("error" => {
        "type" => "invalid_request_error",
        "code" => "invalid_schema",
        "param" => "text.format.schema",
        "message" => "Schema is invalid",
        "raw_request" => "must not be exposed"
      })
    )
    client, _telemetry, settings = external_client(provider: "openai", transport: FakeTransport.new(response))

    error = assert_raises(AiLineSelection::ProviderHttpError) do
      client.call(:meaning, { "entry_text" => "test" }, settings: settings)
    end

    assert_equal %w[code message param type], error.details.fetch(:provider_error).keys.sort
    refute_includes error.details.to_s, "raw_request"
  end

  def test_rate_limit_is_retried_once_and_can_succeed
    transport = FakeTransport.new(http_error(429), openai_response)
    client, telemetry, settings = external_client(provider: "openai", transport: transport)

    invocation = client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)

    assert_equal 2, transport.requests.length
    assert_equal 1, invocation.metadata.fetch(:retry_count)
    assert_equal %w[retrying retry_success], telemetry.events.map { |event| event.fetch(:status) }
  end

  def test_server_error_stops_after_one_retry
    transport = FakeTransport.new(http_error(500), http_error(503))
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::ProviderServerError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_equal 2, transport.requests.length
  end

  def test_timeout_stops_after_one_retry
    timeout = AiLineSelection::ProviderTimeoutError.new("openai")
    transport = FakeTransport.new(timeout, timeout)
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::ProviderTimeoutError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_equal 2, transport.requests.length
  end

  def test_invalid_json_can_succeed_on_the_single_retry
    invalid = openai_response(body: "not-json")
    transport = FakeTransport.new(invalid, openai_response)
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    invocation = client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)

    assert_equal 1, invocation.metadata.fetch(:retry_count)
    assert_equal "response_parse_error", invocation.metadata.fetch(:attempts).first.fetch(:error_code)
  end

  def test_missing_required_field_fails_after_one_retry
    invalid_meaning = valid_meaning.reject { |key, _value| key == "abstraction" }
    transport = FakeTransport.new(
      openai_response(meaning: invalid_meaning),
      openai_response(meaning: invalid_meaning)
    )
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::SchemaValidationError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_equal 2, transport.requests.length
    assert_equal 1, client.last_attempts.last.fetch(:missing_required_count)
  end

  def test_schema_type_violation_fails_after_one_retry
    invalid_meaning = valid_meaning.merge("themes" => "選択")
    transport = FakeTransport.new(
      openai_response(meaning: invalid_meaning),
      openai_response(meaning: invalid_meaning)
    )
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::SchemaValidationError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_equal 2, transport.requests.length
  end

  def test_external_structured_adapter_rejects_embedding_operation
    transport = FakeTransport.new(openai_response)
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::ProviderContractError) do
      client.call(:embedding, { "texts" => ["合成日記"] }, settings: settings)
    end
    assert_empty transport.requests
  end

  def test_openai_embeddings_api_normalizes_vectors_usage_and_request
    transport = FakeTransport.new(openai_embedding_response(count: 2))
    client, telemetry, settings = external_embedding_client(provider: "openai-small", transport: transport)

    invocation = client.call(:embedding, { "texts" => %w[first second] }, settings: settings)

    assert_equal [0, 1], invocation.value.fetch("vectors").map { |item| item.fetch("index") }
    assert_equal 8, invocation.value.dig("vectors", 0, "values").length
    assert_equal 6, invocation.metadata.dig(:usage, :input_units)
    assert_equal "success", telemetry.events.last.fetch(:status)
    body = JSON.parse(transport.requests.first.fetch(:body))
    assert_equal %w[first second], body.fetch("input")
    assert_equal "float", body.fetch("encoding_format")
    assert_equal 8, body.fetch("dimensions")
  end

  def test_openai_embedding_adapter_rejects_non_embedding_operation
    transport = FakeTransport.new(openai_embedding_response(count: 1))
    client, _telemetry, settings = external_embedding_client(provider: "openai-small", transport: transport)

    assert_raises(AiLineSelection::ProviderContractError) do
      client.call(:meaning, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_empty transport.requests
  end
end
