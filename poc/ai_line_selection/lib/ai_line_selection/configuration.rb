# frozen_string_literal: true

require "yaml"

module AiLineSelection
  class Configuration
    attr_reader :root_dir

    def self.load(root_dir: AiLineSelection::ROOT, path: nil)
      new(root_dir: root_dir, path: path || File.join(root_dir, "config", "poc.yml"))
    end

    def initialize(root_dir:, path:)
      @root_dir = File.expand_path(root_dir)
      @path = File.expand_path(path)
      @data = YAML.safe_load_file(@path, permitted_classes: [], aliases: false)
      validate!
    rescue Errno::ENOENT => e
      raise ConfigurationError.new("Configuration file was not found", details: { path: e.path })
    rescue Psych::Exception => e
      raise ConfigurationError.new("Configuration YAML is invalid", details: { error: e.class.name })
    end

    def operation(name)
      @data.fetch("operations").fetch(name.to_s)
    rescue KeyError
      raise ConfigurationError.new("Unknown operation", details: { operation: name.to_s })
    end

    def external_api_enabled?
      @data.dig("external_api", "enabled") == true
    end

    def external_api
      @data.fetch("external_api")
    end

    def meaning_provider(name)
      @data.fetch("meaning_providers").fetch(name.to_s)
    rescue KeyError
      raise ConfigurationError.new("Unknown Meaning provider", details: { provider: name.to_s })
    end

    def safety_provider(name)
      @data.fetch("safety_providers").fetch(name.to_s)
    rescue KeyError
      raise ConfigurationError.new("Unknown SAFETY provider", details: { provider: name.to_s })
    end

    def safety_provider_names
      @data.fetch("safety_providers").keys
    end

    def meaning_provider_names
      @data.fetch("meaning_providers").keys
    end

    def line_evaluation_provider(name)
      @data.fetch("line_evaluation_providers").fetch(name.to_s)
    rescue KeyError
      raise ConfigurationError.new("Unknown Line evaluation provider", details: { provider: name.to_s })
    end

    def line_evaluation_provider_names
      @data.fetch("line_evaluation_providers").keys
    end

    def embedding_provider(name)
      @data.fetch("embedding_providers").fetch(name.to_s)
    rescue KeyError
      raise ConfigurationError.new("Unknown Embedding provider", details: { provider: name.to_s })
    end

    def embedding_provider_names
      @data.fetch("embedding_providers").keys
    end

    def search
      @data.fetch("search")
    end

    def selection
      @data.fetch("selection")
    end

    def random_seed
      @data.fetch("random_seed")
    end

    def path(name)
      relative = @data.fetch("paths").fetch(name.to_s)
      File.expand_path(relative, root_dir)
    rescue KeyError
      raise ConfigurationError.new("Unknown configured path", details: { name: name.to_s })
    end

    def to_safe_h
      {
        version: @data.fetch("version"),
        external_api_enabled: external_api_enabled?,
        total_budget_jpy: external_api.fetch("total_budget_jpy"),
        operations: @data.fetch("operations").transform_values do |value|
          value.slice("adapter", "provider", "model", "prompt_version", "schema_version", "timeout_seconds")
        end
      }
    end

    private

    def validate!
      %w[version random_seed external_api safety_providers meaning_providers line_evaluation_providers embedding_providers operations search selection paths].each do |key|
        raise ConfigurationError.new("Missing configuration section", details: { key: key }) unless @data.key?(key)
      end

      %w[safety meaning embedding line_evaluation].each { |name| operation(name) }

      unless [true, false].include?(external_api["enabled"])
        raise ConfigurationError.new("external_api.enabled must be boolean")
      end

      unless external_api.fetch("maximum_embedding_comparison_requests").to_i.positive?
        raise ConfigurationError.new("external_api.maximum_embedding_comparison_requests must be positive")
      end

      unless external_api.fetch("maximum_safety_comparison_requests").to_i.positive?
        raise ConfigurationError.new("external_api.maximum_safety_comparison_requests must be positive")
      end

      unless external_api.fetch("maximum_line_evaluation_comparison_requests").to_i.positive?
        raise ConfigurationError.new("external_api.maximum_line_evaluation_comparison_requests must be positive")
      end

      if external_api.fetch("total_budget_jpy").to_f.negative?
        raise ConfigurationError.new("external_api.total_budget_jpy must not be negative")
      end

      safety_provider_names.each do |name|
        provider = safety_provider(name)
        %w[adapter provider model max_output_tokens timeout_seconds max_retries pricing].each do |key|
          raise ConfigurationError.new("Missing SAFETY provider setting", details: { provider: name, key: key }) unless provider.key?(key)
        end
        if provider.fetch("adapter") == "fixture"
          unless provider.fetch("max_retries") == 0
            raise ConfigurationError.new("Fixture SAFETY provider must not retry", details: { provider: name })
          end
        else
          %w[endpoint api_key_env].each do |key|
            raise ConfigurationError.new("Missing external SAFETY provider setting", details: { provider: name, key: key }) unless provider.key?(key)
          end
          unless provider.fetch("max_retries") == 1
            raise ConfigurationError.new("External SAFETY provider max_retries must be 1", details: { provider: name })
          end
        end
      end

      safety_output_values = safety_provider_names.map { |name| safety_provider(name).fetch("max_output_tokens") }.uniq
      unless safety_output_values.length == 1
        raise ConfigurationError.new("SAFETY providers must use the same max_output_tokens")
      end


      meaning_provider_names.each do |name|
        provider = meaning_provider(name)
        %w[adapter provider model endpoint api_key_env max_output_tokens timeout_seconds max_retries pricing].each do |key|
          raise ConfigurationError.new("Missing Meaning provider setting", details: { provider: name, key: key }) unless provider.key?(key)
        end
        unless provider.fetch("max_retries") == 1
          raise ConfigurationError.new("Meaning provider max_retries must be 1", details: { provider: name })
        end
      end

      max_output_values = meaning_provider_names.map { |name| meaning_provider(name).fetch("max_output_tokens") }.uniq
      unless max_output_values.length == 1
        raise ConfigurationError.new("Meaning providers must use the same max_output_tokens")
      end

      line_evaluation_provider_names.each do |name|
        provider = line_evaluation_provider(name)
        %w[adapter provider model max_output_tokens timeout_seconds max_retries pricing].each do |key|
          raise ConfigurationError.new("Missing Line evaluation provider setting", details: { provider: name, key: key }) unless provider.key?(key)
        end
        if provider.fetch("adapter") == "fixture"
          unless provider.fetch("max_retries") == 0
            raise ConfigurationError.new("Fixture Line evaluation provider must not retry", details: { provider: name })
          end
        else
          %w[endpoint api_key_env].each do |key|
            raise ConfigurationError.new("Missing external Line evaluation provider setting", details: { provider: name, key: key }) unless provider.key?(key)
          end
          unless provider.fetch("max_retries") == 1
            raise ConfigurationError.new("External Line evaluation provider max_retries must be 1", details: { provider: name })
          end
        end
      end

      line_output_values = line_evaluation_provider_names.map do |name|
        line_evaluation_provider(name).fetch("max_output_tokens")
      end.uniq
      unless line_output_values.length == 1
        raise ConfigurationError.new("Line evaluation providers must use the same max_output_tokens")
      end


      embedding_provider_names.each do |name|
        provider = embedding_provider(name)
        %w[adapter provider model dimensions timeout_seconds max_retries pricing].each do |key|
          raise ConfigurationError.new("Missing Embedding provider setting", details: { provider: name, key: key }) unless provider.key?(key)
        end
        unless provider.fetch("dimensions").to_i.positive?
          raise ConfigurationError.new("Embedding provider dimensions must be positive", details: { provider: name })
        end
        unless [0, 1].include?(provider.fetch("max_retries"))
          raise ConfigurationError.new("Embedding provider max_retries must be 0 or 1", details: { provider: name })
        end
      end
    end
  end
end
