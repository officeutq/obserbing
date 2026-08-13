# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module AiLineSelection
  class Bv2EntryEmbeddingCompletion
    VERSION = "b-v2-entry-embedding-completion-v1"
    EXPECTED_LINE_INDEX_SHA256 = "f36a277daf2d9cf0d6b4d5bfb602f7070387f889d43d3247516f294f5841d2fa"
    EXPECTED_LINE_COUNT = 96
    EXPECTED_OUTCOME_COUNT = 108
    EXPECTED_DIMENSIONS = 1536
    HARD_COST_LIMIT_JPY = 100.0
    USD_TO_JPY = 150.0

    def initialize(configuration:, issue_46_results_dir:, allow_external_api: false,
                   environment: ENV, transport: nil, now: -> { Time.now.utc },
                   expected_line_index_sha256: EXPECTED_LINE_INDEX_SHA256)
      @configuration = configuration
      @issue_46_results_dir = File.expand_path(issue_46_results_dir)
      @allow_external_api = allow_external_api
      @environment = environment
      @transport = transport
      @now = now
      @expected_line_index_sha256 = expected_line_index_sha256
      @data = DataLoader.new(configuration)
      @schemas = SchemaRegistry.new(root_dir: configuration.root_dir)
      @prompts = PromptRegistry.new(root_dir: configuration.root_dir)
    end

    def plan
      source = source_context
      settings = embedding_settings
      attempts = settings.fetch("max_retries", 0) + 1
      bytes = source.fetch(:descriptors).sum { |descriptor| descriptor.fetch(:text).bytesize }
      conservative_tokens = bytes * attempts
      conservative_cost = conservative_tokens * settings.dig("pricing", "input_per_million_usd") / 1_000_000.0 * USD_TO_JPY
      {
        operation: VERSION,
        issue: 59,
        network_call_performed: false,
        source_issue: 46,
        line_index_sha256: source.fetch(:line_index_sha256),
        line_index_hash_matches: true,
        provider_outputs_sha256: source.fetch(:provider_outputs_sha256),
        raw_entry_count: source.fetch(:raw_descriptors).length,
        abstraction_outcome_count: source.fetch(:abstraction_descriptors).length,
        total_embedding_input_count: source.fetch(:descriptors).length,
        normal_api_requests: 1,
        maximum_api_requests_with_retry: attempts,
        batching: "one synchronous embeddings request containing all 144 inputs",
        provider: settings.fetch("provider"),
        model: settings.fetch("model"),
        dimensions: settings.fetch("dimensions"),
        distance: "cosine",
        pricing: settings.fetch("pricing"),
        total_utf8_input_bytes: bytes,
        conservative_input_token_cap_including_retry: conservative_tokens,
        conservative_cost_jpy_including_retry: conservative_cost.round(6),
        hard_cost_limit_jpy: HARD_COST_LIMIT_JPY,
        within_hard_cost_limit: conservative_cost <= HARD_COST_LIMIT_JPY,
        expected_pair_similarity_rows: EXPECTED_OUTCOME_COUNT * EXPECTED_LINE_COUNT,
        allowed_external_operations: ["embedding"],
        prohibited_external_operations: ["safety", "abstraction", "line_profile", "line_embedding", "other_llm"],
        line_embedding_regeneration_supported: false,
        entry_vector_git_persistence_required: false,
        pair_similarity_is_offline_source_of_truth: true,
        source: "fixed_synthetic"
      }
    end

    def call(output_dir:)
      raise ExternalApiDisabledError.new(:embedding) unless @allow_external_api
      planned = plan
      unless planned.fetch(:within_hard_cost_limit)
        raise BudgetExceededError.new(
          estimated_cost_jpy: planned.fetch(:conservative_cost_jpy_including_retry),
          limit_jpy: HARD_COST_LIMIT_JPY
        )
      end

      @output_dir = File.expand_path(output_dir)
      if Dir.exist?(@output_dir) && !Dir.empty?(@output_dir)
        raise ConfigurationError.new("Entry Embedding completion output directory is not empty")
      end
      FileUtils.mkdir_p(@output_dir)
      source = source_context
      invocation = operation_client.call(
        :embedding,
        { "texts" => source.fetch(:descriptors).map { |descriptor| descriptor.fetch(:text) } },
        settings: embedding_settings
      )
      vectors = invocation.value.fetch("vectors").sort_by { |item| item.fetch("index") }.map { |item| item.fetch("values") }
      validate_vectors!(vectors, source.fetch(:descriptors).length)
      usage = invocation.metadata.fetch(:usage)
      raise BudgetExceededError.new(estimated_cost_jpy: usage.fetch(:estimated_cost_jpy), limit_jpy: HARD_COST_LIMIT_JPY) if usage.fetch(:estimated_cost_jpy) > HARD_COST_LIMIT_JPY
      if invocation.metadata.fetch(:attempt_count) > planned.fetch(:maximum_api_requests_with_retry)
        raise DataError.new("Entry Embedding request count exceeded preflight")
      end

      vector_document = build_vector_document(source, vectors, invocation)
      write_json("entry_vectors.json", vector_document)
      pair_rows = build_pair_rows(source, vector_document)
      write_pair_csv("pair_similarities.csv", pair_rows)
      vector_hash = Digest::SHA256.file(artifact_path("entry_vectors.json")).hexdigest
      pair_hash = Digest::SHA256.file(artifact_path("pair_similarities.csv")).hexdigest
      summary = {
        operation: VERSION,
        completed: true,
        embedded_raw_entry_count: source.fetch(:raw_descriptors).length,
        embedded_abstraction_outcome_count: source.fetch(:abstraction_descriptors).length,
        embedded_input_count: vectors.length,
        api_requests_including_retries: invocation.metadata.fetch(:attempt_count),
        usage: usage,
        hard_cost_limit_jpy: HARD_COST_LIMIT_JPY,
        pair_similarity_count: pair_rows.length,
        line_index_sha256: source.fetch(:line_index_sha256),
        entry_vectors_sha256: vector_hash,
        pair_similarities_sha256: pair_hash,
        external_operation_counts: {
          embedding: invocation.metadata.fetch(:attempt_count),
          safety: 0,
          abstraction: 0,
          line_profile: 0,
          line_embedding: 0,
          other_llm: 0
        },
        provider_raw_response_saved: false,
        api_key_saved: false,
        request_id_saved: false,
        results_directory: @output_dir
      }
      write_json("manifest.json", { created_at: @now.call.iso8601, preflight: planned, result: summary })
      write_json("summary.json", summary)
      summary
    rescue AiLineSelection::Error => e
      write_json("stopped.json", { stopped_at: @now.call.iso8601, error_code: e.code, details: e.details }) if @output_dir
      raise
    end

    private

    def source_context
      line_index_path = File.join(@issue_46_results_dir, "line_index.json")
      outputs_path = File.join(@issue_46_results_dir, "provider_outputs.jsonl")
      raise DataError.new("Issue #46 line_index.json is missing") unless File.exist?(line_index_path)
      raise DataError.new("Issue #46 provider_outputs.jsonl is missing") unless File.exist?(outputs_path)
      line_hash = Digest::SHA256.file(line_index_path).hexdigest
      unless line_hash == @expected_line_index_sha256
        raise DataError.new(
          "Issue #46 line index hash mismatch; Line Embedding regeneration is prohibited",
          details: { expected: @expected_line_index_sha256, actual: line_hash }
        )
      end

      line_index = JSON.parse(File.read(line_index_path, encoding: "UTF-8"))
      validate_line_index!(line_index)
      outputs = File.readlines(outputs_path, encoding: "UTF-8").map { |line| JSON.parse(line) }
      validate_outputs!(outputs)
      raw = @data.entries.sort_by { |entry| entry.fetch("id") }.map do |entry|
        { kind: "raw", entry_id: entry.fetch("id"), repetition: nil, text: entry.fetch("body") }
      end
      abstractions = outputs.sort_by { |row| [row.fetch("entry_id"), row.fetch("repetition")] }.map do |row|
        {
          kind: "abstraction", entry_id: row.fetch("entry_id"), repetition: row.fetch("repetition"),
          text: row.fetch("abstraction")
        }
      end
      {
        line_index_path: line_index_path,
        line_index_sha256: line_hash,
        line_index: line_index,
        outputs: outputs,
        provider_outputs_sha256: Digest::SHA256.file(outputs_path).hexdigest,
        raw_descriptors: raw,
        abstraction_descriptors: abstractions,
        descriptors: raw + abstractions
      }
    rescue JSON::ParserError => e
      raise DataError.new("Issue #46 vector sources are invalid JSON", details: { error: e.class.name })
    end

    def validate_line_index!(index)
      ids = index.fetch("line_ids")
      abstraction = index.fetch("abstraction_vectors")
      surface = index.fetch("surface_vectors")
      valid = ids.length == EXPECTED_LINE_COUNT && ids.uniq.length == EXPECTED_LINE_COUNT &&
              abstraction.length == EXPECTED_LINE_COUNT && surface.length == EXPECTED_LINE_COUNT &&
              (abstraction + surface).all? { |vector| vector.length == EXPECTED_DIMENSIONS }
      raise DataError.new("Issue #46 line index dimensions are invalid") unless valid
    end

    def validate_outputs!(outputs)
      slots = outputs.map { |row| [row.fetch("entry_id"), row.fetch("repetition")] }
      valid = outputs.length == EXPECTED_OUTCOME_COUNT && slots.uniq.length == EXPECTED_OUTCOME_COUNT &&
              outputs.all? { |row| row.fetch("safety_classification") == "normal" && row.fetch("abstraction").is_a?(String) }
      raise DataError.new("Issue #46 outcome sources are incomplete") unless valid
    end

    def validate_vectors!(vectors, expected_count)
      valid = vectors.length == expected_count && vectors.all? { |vector| vector.length == EXPECTED_DIMENSIONS }
      raise ProviderContractError.new("Entry Embedding dimensions are invalid", operation: :embedding) unless valid
    end

    def build_vector_document(source, vectors, invocation)
      descriptors = source.fetch(:descriptors)
      rows = descriptors.zip(vectors).map do |descriptor, vector|
        descriptor.slice(:kind, :entry_id, :repetition).transform_keys(&:to_s).merge("values" => vector)
      end
      {
        "version" => VERSION,
        "provider" => invocation.metadata.fetch(:provider),
        "model" => invocation.metadata.fetch(:model),
        "dimensions" => EXPECTED_DIMENSIONS,
        "distance" => "cosine",
        "source_line_index_sha256" => source.fetch(:line_index_sha256),
        "source_provider_outputs_sha256" => source.fetch(:provider_outputs_sha256),
        "vectors" => rows,
        "phase" => phase_metadata(invocation)
      }
    end

    def build_pair_rows(source, document)
      raw_by_entry = document.fetch("vectors").select { |row| row.fetch("kind") == "raw" }.to_h do |row|
        [row.fetch("entry_id"), row.fetch("values")]
      end
      abstraction_by_slot = document.fetch("vectors").select { |row| row.fetch("kind") == "abstraction" }.to_h do |row|
        [[row.fetch("entry_id"), row.fetch("repetition")], row.fetch("values")]
      end
      index = source.fetch(:line_index)
      index.fetch("line_ids").each_with_index.flat_map do |line_id, line_index|
        source.fetch(:outputs).sort_by { |row| [row.fetch("entry_id"), row.fetch("repetition")] }.map do |outcome|
          entry_id = outcome.fetch("entry_id")
          repetition = outcome.fetch("repetition")
          {
            "entry_id" => entry_id,
            "repetition" => repetition,
            "line_id" => line_id,
            "abstraction_similarity" => cosine(
              abstraction_by_slot.fetch([entry_id, repetition]), index.fetch("abstraction_vectors").fetch(line_index)
            ),
            "surface_similarity" => cosine(
              raw_by_entry.fetch(entry_id), index.fetch("surface_vectors").fetch(line_index)
            )
          }
        end
      end.sort_by { |row| [row.fetch("entry_id"), row.fetch("repetition"), row.fetch("line_id")] }
    end

    def operation_client
      OperationClient.new(
        configuration: @configuration,
        schemas: @schemas,
        prompts: @prompts,
        telemetry: Telemetry.new(correlation_id: SecureRandom.uuid, path: nil),
        allow_external_api: true,
        environment: @environment,
        transport: @transport
      )
    end

    def embedding_settings
      @embedding_settings ||= @configuration.embedding_provider("openai-small")
    end

    def phase_metadata(invocation)
      {
        "provider" => invocation.metadata.fetch(:provider),
        "model" => invocation.metadata.fetch(:model),
        "duration_ms" => invocation.metadata.fetch(:duration_ms),
        "attempt_count" => invocation.metadata.fetch(:attempt_count),
        "retry_count" => invocation.metadata.fetch(:retry_count),
        "first_attempt_success" => invocation.metadata.fetch(:first_attempt_success),
        "usage" => invocation.metadata.fetch(:usage)
      }
    end

    def cosine(left, right)
      dot = left.zip(right).sum { |a, b| a * b }
      left_size = Math.sqrt(left.sum { |value| value * value })
      right_size = Math.sqrt(right.sum { |value| value * value })
      return 0.0 if left_size.zero? || right_size.zero?
      (dot / (left_size * right_size)).round(8)
    end

    def write_pair_csv(filename, rows)
      CSV.open(artifact_path(filename), "w:UTF-8", write_headers: true, headers: rows.first.keys) do |csv|
        rows.each { |row| csv << row.values }
      end
    end

    def artifact_path(filename)
      File.join(@output_dir, filename)
    end

    def write_json(filename, value)
      File.write(artifact_path(filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end
  end
end
