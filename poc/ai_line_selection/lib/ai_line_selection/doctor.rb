# frozen_string_literal: true

module AiLineSelection
  class Doctor
    def initialize(configuration)
      @configuration = configuration
    end

    def call
      schemas = SchemaRegistry.new(root_dir: @configuration.root_dir)
      prompts = PromptRegistry.new(root_dir: @configuration.root_dir)
      data = DataLoader.new(@configuration)

      schemas.operations.each { |operation| schemas.fetch(operation) }
      prompts.operations.each { |operation| prompts.fetch(operation) }

      {
        status: "ok",
        ruby_version: RUBY_VERSION,
        external_api_enabled: @configuration.external_api_enabled?,
        external_adapter_implemented: false,
        datasets: {
          entries: data.entries.length,
          lines: data.lines.length,
          approved_lines: data.lines.count { |line| line.fetch("status") == "approved" },
          safety_cases: data.safety_cases.length
        },
        schemas: schemas.operations,
        prompts: prompts.operations
      }
    end
  end
end
