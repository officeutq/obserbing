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
      %w[version random_seed external_api operations search selection paths].each do |key|
        raise ConfigurationError.new("Missing configuration section", details: { key: key }) unless @data.key?(key)
      end

      %w[safety meaning embedding line_evaluation].each { |name| operation(name) }

      unless [true, false].include?(external_api["enabled"])
        raise ConfigurationError.new("external_api.enabled must be boolean")
      end

      if external_api.fetch("total_budget_jpy").to_f.negative?
        raise ConfigurationError.new("external_api.total_budget_jpy must not be negative")
      end
    end
  end
end
