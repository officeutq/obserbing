# frozen_string_literal: true

module AiLineSelection
  class AdapterFactory
    def self.build(name, configuration:, operation:, allow_external_api: false, environment: ENV, transport: nil)
      case name.to_s
      when "fixture"
        Adapters::Fixture.new
      when "pending_external"
        Adapters::PendingExternal.new(configuration: configuration, environment: environment)
      when "openai"
        raise ExternalApiDisabledError.new(operation) unless allow_external_api

        Adapters::OpenAI.new(
          configuration: configuration,
          environment: environment,
          transport: transport || HttpTransport.new
        )
      when "anthropic"
        raise ExternalApiDisabledError.new(operation) unless allow_external_api

        Adapters::Anthropic.new(
          configuration: configuration,
          environment: environment,
          transport: transport || HttpTransport.new
        )
      when "openai_embedding"
        raise ExternalApiDisabledError.new(operation) unless allow_external_api

        Adapters::OpenAIEmbedding.new(
          configuration: configuration,
          environment: environment,
          transport: transport || HttpTransport.new
        )
      else
        return name if name.respond_to?(:call)

        raise ConfigurationError.new("Unknown adapter", details: { adapter: name.to_s })
      end
    end
  end
end
