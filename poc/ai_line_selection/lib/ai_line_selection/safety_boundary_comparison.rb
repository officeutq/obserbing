# frozen_string_literal: true

require "yaml"

module AiLineSelection
  class SafetyBoundaryComparison
    BOUNDARIES = {
      "draft-1" => {
        prompt_file: "safety.md",
        schema_file: "safety.json"
      },
      "additional-v1" => {
        prompt_file: "safety_additional.md",
        schema_file: "safety_additional.json"
      },
      "additional-v2" => {
        prompt_file: "safety_additional_v2.md",
        schema_file: "safety_additional_v2.json"
      },
      "additional-v3" => {
        prompt_file: "safety_additional_v3.md",
        schema_file: "safety_additional_v3.json"
      }
    }.freeze
    DATASETS = %w[additional candidate-full].freeze

    def initialize(configuration:, boundary:, dataset:, **options)
      @configuration = configuration
      @boundary = BOUNDARIES.fetch(boundary.to_s) do
        raise ConfigurationError.new("Unknown SAFETY boundary", details: { boundary: boundary.to_s })
      end
      @boundary_name = boundary.to_s
      @dataset_name = dataset.to_s
      unless DATASETS.include?(@dataset_name)
        raise ConfigurationError.new("Unknown SAFETY boundary dataset", details: { dataset: @dataset_name })
      end
      @options = options
    end

    def plan(providers:, repetitions:, case_ids: nil)
      comparison.plan(providers: providers, repetitions: repetitions, case_ids: case_ids)
    end

    def call(providers:, repetitions:, case_ids: nil, output_dir: nil)
      comparison.call(
        providers: providers,
        repetitions: repetitions,
        case_ids: case_ids,
        output_dir: output_dir
      )
    end

    def cases
      @cases ||= begin
        additional = load_additional_cases
        if @dataset_name == "additional"
          additional
        else
          loader = DataLoader.new(@configuration)
          entries = loader.entries.map do |entry|
            entry.merge("source_set" => "initial_entries", "category" => "existing_normal")
          end
          initial_safety = loader.safety_cases.map do |item|
            item.merge("source_set" => "initial_safety", "category" => "initial_#{item.dig("expected", "safety")}")
          end
          entries + initial_safety + additional
        end
      end
    end

    private

    def comparison
      @comparison ||= SafetyComparison.new(
        configuration: @configuration,
        cases: cases,
        prompt_file: @boundary.fetch(:prompt_file),
        schema_file: @boundary.fetch(:schema_file),
        prompt_version: @boundary_name,
        schema_version: @boundary_name,
        comparison_name: "safety_boundary_#{@boundary_name.tr('-', '_')}_#{@dataset_name.tr('-', '_')}",
        maximum_requests: 216,
        **@options
      )
    end

    def load_additional_cases
      path = File.join(@configuration.root_dir, "data", "additional_safety_cases.yml")
      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      cases = document.fetch("cases")
      ids = cases.map { |item| item.fetch("id") }
      unless ids.uniq.length == ids.length && ids.all? { |id| /^B\d{3}$/.match?(id) }
        raise DataError.new("Additional SAFETY case IDs are invalid")
      end
      cases.each do |item|
        item.fetch("category")
        item.fetch("body")
        expected = item.fetch("expected")
        expected.fetch("safety")
        expected.fetch("reason_code")
      end
      cases.map { |item| item.merge("source_set" => "additional-v1") }
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("Additional SAFETY dataset is invalid", details: { error: e.class.name })
    end
  end
end
