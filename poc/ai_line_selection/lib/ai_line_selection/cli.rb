# frozen_string_literal: true

require "json"
require "optparse"

module AiLineSelection
  class CLI
    def self.start(argv, input: $stdin, output: $stdout, error_output: $stderr)
      new(argv, input: input, output: output, error_output: error_output).start
    end

    def initialize(argv, input:, output:, error_output:)
      @argv = argv.dup
      @input = input
      @output = output
      @error_output = error_output
      EnvironmentLoader.load(root_dir: AiLineSelection::ROOT)
      @configuration = Configuration.load
    end

    def start
      command = @argv.shift || "help"
      case command
      when "doctor" then print_json(Doctor.new(@configuration).call)
      when "run" then run
      when "evaluate" then evaluate
      when "prepare" then prepare
      when "compare-meaning" then compare_meaning
      when "review-meaning" then review_meaning
      when "plan-embedding" then plan_embedding
      when "compare-embedding" then compare_embedding
      else
        @output.puts(help)
      end
      0
    rescue AiLineSelection::Error => e
      @error_output.puts(JSON.pretty_generate(error: e.code, message: e.message, details: e.details))
      2
    rescue OptionParser::ParseError => e
      @error_output.puts(JSON.pretty_generate(error: "invalid_arguments", message: e.message))
      2
    end

    private

    def run
      options = { entry_id: "E001", adapter: nil }
      OptionParser.new do |parser|
        parser.on("--entry-id ID") { |value| options[:entry_id] = value }
        parser.on("--adapter NAME", %w[fixture pending_external]) { |value| options[:adapter] = value }
      end.parse!(@argv)

      result = Runner.new(configuration: @configuration, adapter_override: options[:adapter]).run(entry_id: options[:entry_id])
      print_json(result)
    end

    def prepare
      options = { entry_id: "E001", operation: "safety" }
      OptionParser.new do |parser|
        parser.on("--entry-id ID") { |value| options[:entry_id] = value }
        parser.on("--operation NAME", %w[safety meaning]) { |value| options[:operation] = value }
      end.parse!(@argv)

      data = DataLoader.new(@configuration)
      builder = RequestBuilder.new(
        configuration: @configuration,
        schemas: SchemaRegistry.new(root_dir: @configuration.root_dir),
        prompts: PromptRegistry.new(root_dir: @configuration.root_dir)
      )
      entry = data.entry(options[:entry_id])
      summary = builder.redacted_summary(options[:operation], "entry_text" => entry.fetch("body"))
      print_json(summary.merge(network_call_performed: false))
    end

    def evaluate
      options = { repetitions: 1, adapter: "fixture" }
      OptionParser.new do |parser|
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--adapter NAME", %w[fixture pending_external]) { |value| options[:adapter] = value }
      end.parse!(@argv)

      report = Evaluator.new(configuration: @configuration, adapter: options[:adapter]).call(
        repetitions: options[:repetitions]
      )
      print_json(report)
    end

    def compare_meaning
      options = {
        providers: %w[openai anthropic],
        repetitions: 3,
        entry_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--providers LIST", "Comma-separated: openai,anthropic") do |value|
          options[:providers] = value.split(",").map(&:strip)
        end
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--entry-id ID", "Limit the comparison to one synthetic entry") do |value|
          options[:entry_ids] = [value]
        end
        parser.on("--allow-external-api", "Acknowledge paid external API calls") do
          options[:allow_external_api] = true
        end
      end.parse!(@argv)

      raise ExternalApiDisabledError.new(:meaning) unless options[:allow_external_api]

      report = MeaningComparison.new(
        configuration: @configuration,
        allow_external_api: options[:allow_external_api],
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        providers: options[:providers],
        repetitions: options[:repetitions],
        entry_ids: options[:entry_ids]
      )
      print_json(report)
    end

    def review_meaning
      options = { results: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY", "Meaning comparison results directory") do |value|
          options[:results] = value
        end
      end.parse!(@argv)
      unless options[:results]
        raise ConfigurationError.new("review-meaning requires --results DIRECTORY")
      end

      MeaningReviewer.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        input: @input,
        output: @output
      ).call
    end

    def plan_embedding
      options = embedding_options(allow_external_api_option: false)
      report = EmbeddingComparison.new(configuration: @configuration).plan(
        providers: options.fetch(:providers),
        variants: options.fetch(:variants),
        limits: options.fetch(:limits),
        entry_ids: options.fetch(:entry_ids)
      )
      print_json(report)
    end

    def compare_embedding
      options = embedding_options(allow_external_api_option: true)
      report = EmbeddingComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        providers: options.fetch(:providers),
        variants: options.fetch(:variants),
        limits: options.fetch(:limits),
        entry_ids: options.fetch(:entry_ids)
      )
      print_json(report)
    end

    def embedding_options(allow_external_api_option:)
      options = {
        providers: ["fixture"],
        variants: EmbeddingTextBuilder::VARIANTS,
        limits: EmbeddingComparison::DEFAULT_LIMITS,
        entry_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--providers LIST", "Comma-separated: fixture,openai-small,openai-large") do |value|
          options[:providers] = value.split(",").map(&:strip)
        end
        parser.on("--variants LIST", "Comma-separated: original,meaning_structure,normalized_text") do |value|
          options[:variants] = value.split(",").map(&:strip)
        end
        parser.on("--limits LIST", "Comma-separated positive integers") do |value|
          options[:limits] = value.split(",").map(&:strip)
        end
        parser.on("--entry-id ID", "Limit the comparison to one synthetic entry") do |value|
          options[:entry_ids] = [value]
        end
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid external Embedding API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
    end

    def print_json(value)
      @output.puts(JSON.pretty_generate(value))
    end

    def help
      <<~TEXT
        Usage:
          ruby bin/ai_line_selection doctor
          ruby bin/ai_line_selection run [--entry-id E001] [--adapter fixture|pending_external]
          ruby bin/ai_line_selection evaluate [--repetitions 1] [--adapter fixture|pending_external]
          ruby bin/ai_line_selection prepare [--entry-id E001] [--operation safety|meaning]
          ruby bin/ai_line_selection compare-meaning --providers openai,anthropic --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection compare-meaning --providers openai --repetitions 1 --entry-id E001 --allow-external-api
          ruby bin/ai_line_selection review-meaning --results results/meaning_<timestamp>_<suffix>
          ruby bin/ai_line_selection plan-embedding --providers openai-small,openai-large
          ruby bin/ai_line_selection compare-embedding [--providers fixture] [--variants original,meaning_structure,normalized_text] [--limits 20,50,100]
          ruby bin/ai_line_selection compare-embedding --providers openai-small,openai-large --allow-external-api
      TEXT
    end
  end
end
