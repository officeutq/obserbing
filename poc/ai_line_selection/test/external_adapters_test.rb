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

  def test_external_adapter_rejects_non_meaning_operation
    transport = FakeTransport.new(openai_response)
    client, _telemetry, settings = external_client(provider: "openai", transport: transport)

    assert_raises(AiLineSelection::ProviderContractError) do
      client.call(:safety, { "entry_text" => "合成日記" }, settings: settings)
    end
    assert_empty transport.requests
  end
end
