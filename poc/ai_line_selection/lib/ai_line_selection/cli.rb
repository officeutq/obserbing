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
      when "plan-abstraction" then plan_abstraction
      when "compare-abstraction" then compare_abstraction
      when "plan-b-v2-profile" then plan_b_v2_profile
      when "compare-b-v2-profile" then compare_b_v2_profile
      when "compare-b-v2-band-pass" then compare_b_v2_band_pass
      when "compare-b-v2-selector" then compare_b_v2_selector
      when "plan-b-v2-integrated" then plan_b_v2_integrated
      when "run-b-v2-integrated" then run_b_v2_integrated
      when "evaluate-b-v2-integrated" then evaluate_b_v2_integrated
      when "compare-b-v2-b-v1" then compare_b_v2_b_v1
      when "evaluate-b-v2-gate-a" then evaluate_b_v2_gate_a
      when "decide-b-v2-line-pool-transition" then decide_b_v2_line_pool_transition
      when "plan-b-v2-band-sensitivity" then plan_b_v2_band_sensitivity
      when "complete-b-v2-entry-embeddings" then complete_b_v2_entry_embeddings
      when "prepare-b-v2-band-sweep" then prepare_b_v2_band_sweep
      when "apply-b-v2-band-sweep-codex-review" then apply_b_v2_band_sweep_codex_review
      when "evaluate-b-v2-band-sweep" then evaluate_b_v2_band_sweep
      when "apply-abstraction-preliminary" then apply_abstraction_preliminary
      when "plan-safety" then plan_safety
      when "compare-safety" then compare_safety
      when "plan-safety-boundary" then plan_safety_boundary
      when "compare-safety-boundary" then compare_safety_boundary
      when "plan-embedding" then plan_embedding
      when "compare-embedding" then compare_embedding
      when "plan-abstraction-embedding" then plan_abstraction_embedding
      when "compare-abstraction-embedding" then compare_abstraction_embedding
      when "plan-candidate-quality" then plan_candidate_quality
      when "evaluate-candidate-quality" then evaluate_candidate_quality
      when "plan-grounding-guard" then plan_grounding_guard
      when "compare-grounding-guard" then compare_grounding_guard
      when "export-selection-inputs" then export_selection_inputs
      when "plan-ruby-selection" then plan_ruby_selection
      when "compare-ruby-selection" then compare_ruby_selection
      when "plan-abstraction-only-integrated" then plan_abstraction_only_integrated
      when "run-abstraction-only-integrated" then run_abstraction_only_integrated
      when "replay-abstraction-only-integrated" then replay_abstraction_only_integrated
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

    def plan_abstraction
      options = abstraction_options(allow_external_api_option: false)
      print_json(AbstractionComparison.new(
        configuration: @configuration,
        version: options.fetch(:version)
      ).plan(
        provider: options.fetch(:provider),
        embedding_provider: options.fetch(:embedding_provider),
        repetitions: options.fetch(:repetitions),
        item_ids: options.fetch(:item_ids)
      ))
    end

    def compare_abstraction
      options = abstraction_options(allow_external_api_option: true)
      print_json(AbstractionComparison.new(
        configuration: @configuration,
        version: options.fetch(:version),
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        provider: options.fetch(:provider),
        embedding_provider: options.fetch(:embedding_provider),
        repetitions: options.fetch(:repetitions),
        item_ids: options.fetch(:item_ids)
      ))
    end

    def abstraction_options(allow_external_api_option:)
      options = {
        provider: "fixture",
        embedding_provider: "fixture",
        version: "abstraction-only-v2",
        repetitions: 3,
        item_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--provider NAME", %w[fixture openai anthropic]) { |value| options[:provider] = value }
        parser.on("--embedding-provider NAME", @configuration.embedding_provider_names) do |value|
          options[:embedding_provider] = value
        end
        parser.on("--version NAME", AbstractionComparison::VERSIONS.keys) { |value| options[:version] = value }
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--item-id ID", "Limit the comparison to one Entry or Line") do |value|
          options[:item_ids] = [value]
        end
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid abstraction and Embedding API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
    end

    def plan_b_v2_profile
      options = b_v2_profile_options(allow_external_api_option: false)
      print_json(Bv2ProfileComparison.new(configuration: @configuration).plan(
        provider: options.fetch(:provider),
        versions: options.fetch(:versions),
        repetitions: options.fetch(:repetitions)
      ))
    end

    def compare_b_v2_profile
      options = b_v2_profile_options(allow_external_api_option: true)
      print_json(Bv2ProfileComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        provider: options.fetch(:provider),
        versions: options.fetch(:versions),
        repetitions: options.fetch(:repetitions)
      ))
    end

    def b_v2_profile_options(allow_external_api_option:)
      options = {
        provider: "openai",
        versions: Bv2ProfileComparison::VERSIONS.keys,
        repetitions: Bv2ProfileComparison::REPETITIONS,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--provider NAME", @configuration.meaning_provider_names) { |value| options[:provider] = value }
        parser.on("--versions LIST", "Comma-separated B-v2 profile versions") do |value|
          options[:versions] = value.split(",").map(&:strip)
        end
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid profile API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
    end

    def compare_b_v2_band_pass
      options = { abstraction_results: nil, surface_results: nil, output: nil }
      OptionParser.new do |parser|
        parser.on("--abstraction-results DIRECTORY") { |value| options[:abstraction_results] = value }
        parser.on("--surface-results DIRECTORY") { |value| options[:surface_results] = value }
        parser.on("--output FILE") { |value| options[:output] = value }
      end.parse!(@argv)
      unless options[:abstraction_results] && options[:surface_results]
        raise ConfigurationError.new("compare-b-v2-band-pass requires --abstraction-results and --surface-results")
      end

      print_json(Bv2BandPassOffline.new(
        configuration: @configuration,
        abstraction_results_dir: options.fetch(:abstraction_results),
        surface_results_dir: options.fetch(:surface_results)
      ).call(output_path: options.fetch(:output)))
    end

    def compare_b_v2_selector
      options = { abstraction_results: nil, output: nil }
      OptionParser.new do |parser|
        parser.on("--abstraction-results DIRECTORY") { |value| options[:abstraction_results] = value }
        parser.on("--output FILE") { |value| options[:output] = value }
      end.parse!(@argv)
      unless options[:abstraction_results]
        raise ConfigurationError.new("compare-b-v2-selector requires --abstraction-results")
      end

      print_json(Bv2SelectorComparison.new(
        configuration: @configuration,
        abstraction_results_dir: options.fetch(:abstraction_results)
      ).call(output_path: options.fetch(:output)))
    end

    def plan_b_v2_integrated
      print_json(Bv2IntegratedComparison.new(configuration: @configuration).plan)
    end

    def run_b_v2_integrated
      options = { output_dir: nil, resume: false, allow_external_api: false, repair_safety_overblocks: false }
      OptionParser.new do |parser|
        parser.on("--output-dir DIRECTORY") { |value| options[:output_dir] = value }
        parser.on("--resume") { options[:resume] = true }
        parser.on("--repair-safety-overblocks") { options[:repair_safety_overblocks] = true }
        parser.on("--allow-external-api") { options[:allow_external_api] = true }
      end.parse!(@argv)
      raise ConfigurationError.new("run-b-v2-integrated requires --output-dir") unless options[:output_dir]

      print_json(Bv2IntegratedComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        output_dir: options.fetch(:output_dir),
        resume: options.fetch(:resume),
        repair_safety_overblocks: options.fetch(:repair_safety_overblocks)
      ))
    end

    def evaluate_b_v2_integrated
      options = { results: nil, judgments: nil, output: nil, outcomes: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--judgments FILE") { |value| options[:judgments] = value }
        parser.on("--output FILE") { |value| options[:output] = value }
        parser.on("--outcomes FILE") { |value| options[:outcomes] = value }
      end.parse!(@argv)
      unless options[:results] && options[:judgments]
        raise ConfigurationError.new("evaluate-b-v2-integrated requires --results and --judgments")
      end

      print_json(Bv2IntegratedEvaluator.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        judgments_path: options.fetch(:judgments)
      ).call(output_path: options[:output], outcomes_path: options[:outcomes]))
    end

    def compare_b_v2_b_v1
      options = { output: nil }
      OptionParser.new do |parser|
        parser.on("--output FILE") { |value| options[:output] = value }
      end.parse!(@argv)
      print_json(Bv2VsBv1Comparison.new(configuration: @configuration).call(output_path: options[:output]))
    end

    def evaluate_b_v2_gate_a
      options = { output: nil }
      OptionParser.new do |parser|
        parser.on("--output FILE") { |value| options[:output] = value }
      end.parse!(@argv)
      print_json(Bv2GateAEvaluator.new(configuration: @configuration).call(output_path: options[:output]))
    end

    def decide_b_v2_line_pool_transition
      options = { output: nil }
      OptionParser.new do |parser|
        parser.on("--output FILE") { |value| options[:output] = value }
      end.parse!(@argv)
      print_json(Bv2LinePoolTransition.new(configuration: @configuration).call(output_path: options[:output]))
    end

    def plan_b_v2_band_sensitivity
      options = { results: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
      end.parse!(@argv)
      raise ConfigurationError.new("plan-b-v2-band-sensitivity requires --results") unless options[:results]

      print_json(Bv2EntryEmbeddingCompletion.new(
        configuration: @configuration,
        issue_46_results_dir: options.fetch(:results)
      ).plan)
    end

    def complete_b_v2_entry_embeddings
      options = { results: nil, output_dir: nil, allow_external_api: false }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--output-dir DIRECTORY") { |value| options[:output_dir] = value }
        parser.on("--allow-external-api") { options[:allow_external_api] = true }
      end.parse!(@argv)
      unless options[:results] && options[:output_dir]
        raise ConfigurationError.new("complete-b-v2-entry-embeddings requires --results and --output-dir")
      end

      print_json(Bv2EntryEmbeddingCompletion.new(
        configuration: @configuration,
        issue_46_results_dir: options.fetch(:results),
        allow_external_api: options.fetch(:allow_external_api)
      ).call(output_dir: options.fetch(:output_dir)))
    end

    def prepare_b_v2_band_sweep
      options = { results: nil, completion_results: nil, output_dir: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--completion-results DIRECTORY") { |value| options[:completion_results] = value }
        parser.on("--output-dir DIRECTORY") { |value| options[:output_dir] = value }
      end.parse!(@argv)
      unless options.values_at(:results, :completion_results, :output_dir).all?
        raise ConfigurationError.new("prepare-b-v2-band-sweep requires --results, --completion-results and --output-dir")
      end

      print_json(Bv2BandSensitivity.new(
        configuration: @configuration,
        issue_46_results_dir: options.fetch(:results),
        completion_results_dir: options.fetch(:completion_results)
      ).prepare(output_dir: options.fetch(:output_dir)))
    end

    def apply_b_v2_band_sweep_codex_review
      options = { results: nil, completion_results: nil, output_dir: nil, review: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--completion-results DIRECTORY") { |value| options[:completion_results] = value }
        parser.on("--output-dir DIRECTORY") { |value| options[:output_dir] = value }
        parser.on("--review FILE") { |value| options[:review] = value }
      end.parse!(@argv)
      unless options.values_at(:results, :completion_results, :output_dir, :review).all?
        raise ConfigurationError.new("apply-b-v2-band-sweep-codex-review requires --results, --completion-results, --output-dir and --review")
      end

      print_json(Bv2BandSensitivity.new(
        configuration: @configuration,
        issue_46_results_dir: options.fetch(:results),
        completion_results_dir: options.fetch(:completion_results)
      ).apply_codex_review(output_dir: options.fetch(:output_dir), review_path: options.fetch(:review)))
    end

    def evaluate_b_v2_band_sweep
      options = { results: nil, completion_results: nil, output_dir: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--completion-results DIRECTORY") { |value| options[:completion_results] = value }
        parser.on("--output-dir DIRECTORY") { |value| options[:output_dir] = value }
      end.parse!(@argv)
      unless options.values_at(:results, :completion_results, :output_dir).all?
        raise ConfigurationError.new("evaluate-b-v2-band-sweep requires --results, --completion-results and --output-dir")
      end

      print_json(Bv2BandSensitivity.new(
        configuration: @configuration,
        issue_46_results_dir: options.fetch(:results),
        completion_results_dir: options.fetch(:completion_results)
      ).evaluate(output_dir: options.fetch(:output_dir)))
    end

    def apply_abstraction_preliminary
      options = { results: nil, judgments: nil, export: nil, export_repetitions: nil }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--judgments FILE") { |value| options[:judgments] = value }
        parser.on("--export FILE") { |value| options[:export] = value }
        parser.on("--export-repetitions FILE") { |value| options[:export_repetitions] = value }
      end.parse!(@argv)
      unless options[:results] && options[:judgments]
        raise ConfigurationError.new("apply-abstraction-preliminary requires --results and --judgments")
      end

      print_json(AbstractionPreliminaryReviewer.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        judgments_path: options.fetch(:judgments),
        export_path: options.fetch(:export),
        repetitions_export_path: options.fetch(:export_repetitions)
      ).call)
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

    def plan_safety_boundary
      options = safety_boundary_options(allow_external_api_option: false)
      report = SafetyBoundaryComparison.new(
        configuration: @configuration,
        boundary: options.fetch(:boundary),
        dataset: options.fetch(:dataset)
      ).plan(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        case_ids: options.fetch(:case_ids)
      )
      print_json(report)
    end

    def compare_safety_boundary
      options = safety_boundary_options(allow_external_api_option: true)
      report = SafetyBoundaryComparison.new(
        configuration: @configuration,
        boundary: options.fetch(:boundary),
        dataset: options.fetch(:dataset),
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        providers: options.fetch(:providers),
        repetitions: options.fetch(:repetitions),
        case_ids: options.fetch(:case_ids)
      )
      print_json(report)
    end

    def safety_boundary_options(allow_external_api_option:)
      options = {
        providers: ["fixture"],
        repetitions: 3,
        boundary: "additional-v3",
        dataset: "candidate-full",
        case_ids: nil,
        allow_external_api: false
      }
      OptionParser.new do |parser|
        parser.on("--providers LIST", "Comma-separated: fixture,openai") do |value|
          options[:providers] = value.split(",").map(&:strip)
        end
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--boundary NAME", SafetyBoundaryComparison::BOUNDARIES.keys) { |value| options[:boundary] = value }
        parser.on("--dataset NAME", SafetyBoundaryComparison::DATASETS) { |value| options[:dataset] = value }
        parser.on("--case-id ID") { |value| options[:case_ids] = [value] }
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

    def plan_abstraction_embedding
      options = abstraction_embedding_options(allow_external_api_option: false)
      print_json(AbstractionEmbeddingComparison.new(configuration: @configuration).plan(
        provider: options.fetch(:provider),
        entry_ids: options.fetch(:entry_ids)
      ))
    end

    def compare_abstraction_embedding
      options = abstraction_embedding_options(allow_external_api_option: true)
      print_json(AbstractionEmbeddingComparison.new(
        configuration: @configuration,
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        provider: options.fetch(:provider),
        entry_ids: options.fetch(:entry_ids)
      ))
    end

    def abstraction_embedding_options(allow_external_api_option:)
      options = { provider: "fixture", entry_ids: nil, allow_external_api: false }
      OptionParser.new do |parser|
        parser.on("--provider NAME", @configuration.embedding_provider_names) { |value| options[:provider] = value }
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

    def plan_candidate_quality
      options = candidate_quality_options(allow_external_api_option: false)
      print_json(CandidateQualityComparison.new(
        configuration: @configuration,
        results_dir: options.fetch(:results)
      ).plan(provider: options.fetch(:provider)))
    end

    def evaluate_candidate_quality
      options = candidate_quality_options(allow_external_api_option: true)
      print_json(CandidateQualityComparison.new(
        configuration: @configuration,
        results_dir: options.fetch(:results),
        allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(provider: options.fetch(:provider)))
    end

    def candidate_quality_options(allow_external_api_option:)
      options = { provider: "openai", results: nil, allow_external_api: false }
      OptionParser.new do |parser|
        parser.on("--provider NAME", @configuration.line_evaluation_provider_names) { |value| options[:provider] = value }
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid offline candidate quality calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      raise ConfigurationError.new("candidate quality requires --results DIRECTORY") unless options[:results]

      options
    end

    def plan_grounding_guard
      print_json(GroundingGuardComparison.new(configuration: @configuration).plan)
    end

    def compare_grounding_guard
      print_json(GroundingGuardComparison.new(configuration: @configuration).call)
    end

    def export_selection_inputs
      options = { results: nil, export: File.join(@configuration.root_dir, "data", "evaluations", "ruby_selection_inputs_v1.json") }
      OptionParser.new do |parser|
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--export FILE") { |value| options[:export] = value }
      end.parse!(@argv)
      raise ConfigurationError.new("export-selection-inputs requires --results DIRECTORY") unless options[:results]

      print_json(SelectionInputSnapshot.export(results_dir: options.fetch(:results), output_path: options.fetch(:export)))
    end

    def plan_ruby_selection
      print_json(RuleBasedSelectionComparison.new(configuration: @configuration).plan)
    end

    def compare_ruby_selection
      print_json(RuleBasedSelectionComparison.new(configuration: @configuration).call)
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

    def plan_abstraction_only_integrated
      options = abstraction_only_integrated_options(default_mode: "diagnostic", allow_external_api_option: false)
      print_json(AbstractionOnlyIntegratedComparison.new(configuration: @configuration).plan(
        mode: options.fetch(:mode), repetitions: options.fetch(:repetitions),
        entry_ids: options.fetch(:entry_ids), include_offline_quality: options.fetch(:include_offline_quality)
      ))
    end

    def run_abstraction_only_integrated
      options = abstraction_only_integrated_options(default_mode: "fixture", allow_external_api_option: true)
      print_json(AbstractionOnlyIntegratedComparison.new(
        configuration: @configuration, allow_external_api: options.fetch(:allow_external_api),
        progress: ->(message) { @error_output.puts(message) }
      ).call(
        mode: options.fetch(:mode), repetitions: options.fetch(:repetitions),
        entry_ids: options.fetch(:entry_ids), include_offline_quality: options.fetch(:include_offline_quality),
        output_dir: options.fetch(:results)
      ))
    end

    def abstraction_only_integrated_options(default_mode:, allow_external_api_option:)
      options = {
        mode: default_mode, repetitions: 3, entry_ids: nil,
        include_offline_quality: true, allow_external_api: false, results: nil
      }
      OptionParser.new do |parser|
        parser.on("--mode NAME", AbstractionOnlyIntegratedComparison::MODES) { |value| options[:mode] = value }
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
        parser.on("--entry-id ID") { |value| options[:entry_ids] = [value] }
        parser.on("--results DIRECTORY", "Resume in an existing results directory") { |value| options[:results] = value }
        parser.on("--skip-offline-quality") { options[:include_offline_quality] = false }
        if allow_external_api_option
          parser.on("--allow-external-api", "Acknowledge paid external integrated API calls") do
            options[:allow_external_api] = true
          end
        end
      end.parse!(@argv)
      options
    end

    def replay_abstraction_only_integrated
      options = { safety: nil, abstraction: nil, embedding: nil, reviews: nil, results: nil, repetitions: 3 }
      OptionParser.new do |parser|
        parser.on("--safety-results DIRECTORY") { |value| options[:safety] = value }
        parser.on("--abstraction-results DIRECTORY") { |value| options[:abstraction] = value }
        parser.on("--embedding-results DIRECTORY") { |value| options[:embedding] = value }
        parser.on("--reviews FILE") { |value| options[:reviews] = value }
        parser.on("--results DIRECTORY") { |value| options[:results] = value }
        parser.on("--repetitions N", Integer) { |value| options[:repetitions] = value }
      end.parse!(@argv)
      unless options.values_at(:safety, :abstraction, :embedding).all?
        raise ConfigurationError.new("replay-abstraction-only-integrated requires all three source result directories")
      end
      print_json(AbstractionOnlyIntegratedReplay.new(
        configuration: @configuration, safety_results: options.fetch(:safety),
        abstraction_results: options.fetch(:abstraction), embedding_results: options.fetch(:embedding),
        reviews_path: options.fetch(:reviews)
      ).call(repetitions: options.fetch(:repetitions), output_dir: options.fetch(:results)))
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
          ruby bin/ai_line_selection plan-abstraction --version abstraction-only-v2 --provider openai --embedding-provider openai-small --repetitions 3
          ruby bin/ai_line_selection compare-abstraction --version abstraction-only-v2 --provider openai --embedding-provider openai-small --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection apply-abstraction-preliminary --results results/abstraction_<version>_<timestamp>_<suffix> --judgments reviews/abstraction_only_v2_codex_preliminary.yml --export data/abstractions/abstraction_only_v2.yml --export-repetitions data/abstractions/abstraction_only_v2_repetitions.yml
          ruby bin/ai_line_selection plan-safety --providers openai,anthropic --repetitions 3
          ruby bin/ai_line_selection compare-safety [--providers fixture] [--repetitions 1]
          ruby bin/ai_line_selection compare-safety --providers openai,anthropic --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection plan-safety-boundary --boundary additional-v3 --dataset candidate-full --providers openai
          ruby bin/ai_line_selection compare-safety-boundary --boundary additional-v3 --dataset candidate-full --providers openai --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection plan-embedding --providers openai-small,openai-large
          ruby bin/ai_line_selection compare-embedding [--providers fixture] [--variants original,meaning_structure,normalized_text] [--limits 20,50,100]
          ruby bin/ai_line_selection compare-embedding --providers openai-small,openai-large --allow-external-api
          ruby bin/ai_line_selection plan-abstraction-embedding --provider openai-small
          ruby bin/ai_line_selection compare-abstraction-embedding --provider openai-small --allow-external-api
          ruby bin/ai_line_selection plan-candidate-quality --provider openai --results results/abstraction_embedding_<timestamp>_<suffix>
          ruby bin/ai_line_selection evaluate-candidate-quality --provider openai --results results/abstraction_embedding_<timestamp>_<suffix> --allow-external-api
          ruby bin/ai_line_selection plan-grounding-guard
          ruby bin/ai_line_selection compare-grounding-guard
          ruby bin/ai_line_selection export-selection-inputs --results results/abstraction_embedding_<timestamp>_<suffix> --export data/evaluations/ruby_selection_inputs_v1.json
          ruby bin/ai_line_selection plan-ruby-selection
          ruby bin/ai_line_selection compare-ruby-selection
          ruby bin/ai_line_selection plan-abstraction-only-integrated --mode diagnostic --repetitions 3
          ruby bin/ai_line_selection run-abstraction-only-integrated --mode fixture --repetitions 3
          ruby bin/ai_line_selection run-abstraction-only-integrated --mode diagnostic --repetitions 3 --allow-external-api
          ruby bin/ai_line_selection replay-abstraction-only-integrated --safety-results results/safety_<...> --abstraction-results results/abstraction_<...> --embedding-results results/abstraction_embedding_<...>
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
