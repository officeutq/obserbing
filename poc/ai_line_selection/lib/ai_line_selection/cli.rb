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
      when "plan-safety" then plan_safety
      when "compare-safety" then compare_safety
      when "plan-embedding" then plan_embedding
      when "compare-embedding" then compare_embedding
      when "plan-line-evaluation" then plan_line_evaluation
      when "compare-line-evaluation" then compare_line_evaluation
      when "review-line-evaluation" then review_line_evaluation
      when "apply-line-preliminary" then apply_line_preliminary
      when "plan-integrated" then plan_integrated
      when "run-integrated" then run_integrated
      when "review-integrated" then review_integrated
      when "apply-integrated-preliminary" then apply_integrated_preliminary
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

    def plan_safety
      options = safety_options(
        default_providers: %w[openai anthropic],
        default_repetitions: 3,
        allow_external_api_option: false
      )
      print_json(SafetyComparison.new(configuration: @configuration).plan(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        case_ids: options.fetch(:case_ids)
      ))
    end

    def compare_safety
      options = safety_options(
        default_providers: ["fixture"],
        default_repetitions: 1,
        allow_external_api_option: true
      )
      print_json(SafetyComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        case_ids: options.fetch(:case_ids)
      ))
    end

    def safety_options(default_providers:, default_repetitions:, allow_external_api_option:)
      options = {
        providers: default_providers,
        repetitions: default_repetitions,
        case_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--providers LIST", "Comma-separated: fixture,openai,anthropic") do |value|
          options[:providers] = value.split(",").map(&:strip)
        end
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--case-id ID", "Limit the comparison to one synthetic SAFETY case") do |value|
          options[:case_ids] = [value]
        end
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid external SAFETY API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
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

    def plan_line_evaluation
      options = line_evaluation_options(
        default_providers: %w[openai anthropic],
        default_embedding_provider: LineEvaluationComparison::DEFAULT_EMBEDDING_PROVIDER,
        default_repetitions: 3,
        allow_external_api_option: false
      )
      report = LineEvaluationComparison.new(configuration: @configuration).plan(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        entry_ids: options.fetch(:entry_ids),
        embedding_provider: options.fetch(:embedding_provider)
      )
      print_json(report)
    end

    def compare_line_evaluation
      options = line_evaluation_options(
        default_providers: ["fixture"],
        default_embedding_provider: "fixture",
        default_repetitions: 1,
        allow_external_api_option: true
      )
      report = LineEvaluationComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        entry_ids: options.fetch(:entry_ids),
        embedding_provider: options.fetch(:embedding_provider)
      )
      print_json(report)
    end

    def line_evaluation_options(default_providers:, default_embedding_provider:, default_repetitions:, allow_external_api_option:)
      options = {
        providers: default_providers,
        embedding_provider: default_embedding_provider,
        repetitions: default_repetitions,
        entry_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--providers LIST", "Comma-separated: fixture,openai,anthropic") do |value|
          options[:providers] = value.split(",").map(&:strip)
        end
        parser.on("--embedding-provider NAME", "fixture or openai-small") do |value|
          options[:embedding_provider] = value
        end
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--entry-id ID", "Limit the comparison to one synthetic entry") do |value|
          options[:entry_ids] = [value]
        end
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid external API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
    end

    def review_line_evaluation
      options = { results: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY", "Line evaluation comparison results directory") do |value|
          options[:results] = value
        end
      end.parse!(@argv)
      unless options[:results]
        raise ConfigurationError.new("review-line-evaluation requires --results DIRECTORY")
      end

      LineEvaluationReviewer.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        input: @input,
        output: @output
      ).call
    end

    def apply_line_preliminary
      options = { results: nil, judgments: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY", "Line evaluation comparison results directory") do |value|
          options[:results] = value
        end
        parser.on("--judgments FILE", "Complete Codex preliminary judgment JSON") do |value|
          options[:judgments] = value
        end
      end.parse!(@argv)
      unless options[:results] && options[:judgments]
        raise ConfigurationError.new("apply-line-preliminary requires --results and --judgments")
      end

      print_json(LineEvaluationPreliminaryImporter.new(
        results_dir: options.fetch(:results),
        judgments_path: options.fetch(:judgments)
      ).call)
    end

    def plan_integrated
      options = integrated_options(default_mode: "selected", allow_external_api_option: false)
      print_json(IntegratedComparison.new(configuration: @configuration).plan(
        mode: options.fetch(:mode),
        repetitions: options.fetch(:repetitions),
        safety_case_repetitions: options.fetch(:safety_case_repetitions),
        entry_ids: options.fetch(:entry_ids)
      ))
    end

    def run_integrated
      options = integrated_options(default_mode: "fixture", allow_external_api_option: true)
      print_json(IntegratedComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        mode: options.fetch(:mode),
        repetitions: options.fetch(:repetitions),
        safety_case_repetitions: options.fetch(:safety_case_repetitions),
        entry_ids: options.fetch(:entry_ids)
      ))
    end

    def integrated_options(default_mode:, allow_external_api_option:)
      options = {
        mode: default_mode,
        repetitions: nil,
        safety_case_repetitions: nil,
        entry_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--mode NAME", IntegratedComparison::MODES) { |value| options[:mode] = value }
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--safety-repetitions N", Integer) { |value| options[:safety_case_repetitions] = value }
        parser.on("--entry-id ID", "Limit the normal flow to one synthetic entry") do |value|
          options[:entry_ids] = [value]
        end
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid external integrated API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)

      defaults = options.fetch(:mode) == "selected" ? @configuration.integrated : {}
      options[:repetitions] ||= defaults.fetch("repetitions", 1)
      options[:safety_case_repetitions] ||= defaults.fetch("safety_case_repetitions", 1)
      options
    end

    def review_integrated
      options = results_directory_options("review-integrated", "Integrated comparison results directory")
      LineEvaluationReviewer.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        input: @input,
        output: @output
      ).call
    end

    def apply_integrated_preliminary
      options = preliminary_options("apply-integrated-preliminary")
      print_json(LineEvaluationPreliminaryImporter.new(
        results_dir: options.fetch(:results),
        judgments_path: options.fetch(:judgments)
      ).call)
    end

    def results_directory_options(command, description)
      options = { results: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY", description) { |value| options[:results] = value }
      end.parse!(@argv)
      raise ConfigurationError.new("#{command} requires --results DIRECTORY") unless options[:results]

      options
    end

    def preliminary_options(command)
      options = { results: nil, judgments: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY", "Integrated comparison results directory") do |value|
          options[:results] = value
        end
        parser.on("--judgments FILE", "Complete Codex preliminary judgment JSON") do |value|
          options[:judgments] = value
        end
      end.parse!(@argv)
      unless options[:results] && options[:judgments]
        raise ConfigurationError.new("#{command} requires --results and --judgments")
      end

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
          ruby bin/ai_line_selection plan-safety --providers openai,anthropic --repetitions 3
          ruby bin/ai_line_selection compare-safety [--providers fixture] [--repetitions 1]
          ruby bin/ai_line_selection compare-safety --providers openai,anthropic --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection plan-embedding --providers openai-small,openai-large
          ruby bin/ai_line_selection compare-embedding [--providers fixture] [--variants original,meaning_structure,normalized_text] [--limits 20,50,100]
          ruby bin/ai_line_selection compare-embedding --providers openai-small,openai-large --allow-external-api
          ruby bin/ai_line_selection plan-line-evaluation --providers openai,anthropic --repetitions 3
          ruby bin/ai_line_selection compare-line-evaluation [--providers fixture] [--embedding-provider fixture] [--repetitions 1]
          ruby bin/ai_line_selection compare-line-evaluation --providers openai,anthropic --embedding-provider openai-small --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection review-line-evaluation --results results/line_evaluation_<timestamp>_<suffix>
          ruby bin/ai_line_selection apply-line-preliminary --results results/line_evaluation_<timestamp>_<suffix> --judgments preliminary.json
          ruby bin/ai_line_selection plan-integrated [--mode selected] [--repetitions 3] [--safety-repetitions 3]
          ruby bin/ai_line_selection run-integrated [--mode fixture] [--repetitions 1] [--safety-repetitions 1]
          ruby bin/ai_line_selection run-integrated --mode selected --allow-external-api
          ruby bin/ai_line_selection review-integrated --results results/integrated_<timestamp>_<suffix>
          ruby bin/ai_line_selection apply-integrated-preliminary --results results/integrated_<timestamp>_<suffix> --judgments preliminary.json
      TEXT
    end
  end
end
