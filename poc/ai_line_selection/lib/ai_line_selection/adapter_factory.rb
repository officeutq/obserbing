# frozen_string_literal: true

module AiLineSelection
  class AdapterFactory
    def self.build(name, configuration:, allow_external_api: false, environment: ENV, transport: nil)
      case name.to_s
      when "fixture"
        Adapters::Fixture.new
      when "pending_external"
        Adapters::PendingExternal.new(configuration: configuration, environment: environment)
      when "openai"
        raise ExternalApiDisabledError.new(:meaning) unless allow_external_api

        Adapters::OpenAI.new(
          configuration: configuration,
          environment: environment,
          transport: transport || HttpTransport.new
        )
      when "anthropic"
        raise ExternalApiDisabledError.new(:meaning) unless allow_external_api

        Adapters::Anthropic.new(
          configuration: configuration,
          environment: environment,
          transport: transport || HttpTransport.new
        )
      else
        raise ConfigurationError.new("Unknown adapter", details: { adapter: name.to_s })
      end
    end
  end
end
