# frozen_string_literal: true

module AiLineSelection
  class AdapterFactory
    def self.build(name, configuration:)
      case name.to_s
      when "fixture"
        Adapters::Fixture.new
      when "pending_external"
        Adapters::PendingExternal.new(configuration: configuration)
      else
        raise ConfigurationError.new("Unknown adapter", details: { adapter: name.to_s })
      end
    end
  end
end
