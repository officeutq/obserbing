# frozen_string_literal: true

require "csv"
require "digest"
require "json"

module AiLineSelection
  class SelectionInputSnapshot
    VERSION = "ruby-selection-input-v1"
    MODE = "abstraction_only_v2"
    REPETITION = 1
    TOP_N = 5

    def self.export(results_dir:, output_path:)
      new(results_dir: results_dir).export(output_path: output_path)
    end

    def initialize(results_dir:)
      @results_dir = File.expand_path(results_dir)
    end

    def export(output_path:)
      mappings = CSV.read(path("blind_mapping.csv"), headers: true, encoding: "UTF-8")
      blind_by_entry = mappings.select { |row| row.fetch("mode") == MODE }.to_h do |row|
        [row.fetch("entry_id"), row.fetch("blind_set_id")]
      end
      candidate_records = read_jsonl("candidate_sets.jsonl").select do |record|
        record.fetch("mode") == MODE && record.fetch("repetition") == REPETITION
      end
      quality_by_key = read_jsonl("candidate_quality_outputs.jsonl").to_h do |record|
        [[record.fetch("blind_set_id"), record.fetch("line_id")], record]
      end
      entries = candidate_records.sort_by { |record| record.fetch("entry_id") }.map do |record|
        entry_id = record.fetch("entry_id")
        blind_id = blind_by_entry.fetch(entry_id)
        candidates = record.fetch("top_candidates").first(TOP_N).map do |candidate|
          quality = quality_by_key.fetch([blind_id, candidate.fetch("line_id")])
          {
            rank: candidate.fetch("rank"),
            line_id: candidate.fetch("line_id"),
            similarity: candidate.fetch("similarity"),
            blind_quality: quality.slice(
              "acceptable", "distance", "clearly_unrelated", "fatal_grounding_mismatch", "confidence"
            )
          }
        end
        { entry_id: entry_id, candidates: candidates }
      end
      validate_entries!(entries)
      document = {
        version: VERSION,
        source: "synthetic",
        mode: MODE,
        repetition: REPETITION,
        quality_top_n: TOP_N,
        methodology: {
          mode_hidden_during_source_evaluation: true,
          entry_and_line_text_removed: true,
          evaluator_reason_removed: true
        },
        source_hashes: {
          candidate_sets_sha256: Digest::SHA256.file(path("candidate_sets.jsonl")).hexdigest,
          blind_mapping_sha256: Digest::SHA256.file(path("blind_mapping.csv")).hexdigest,
          candidate_quality_outputs_sha256: Digest::SHA256.file(path("candidate_quality_outputs.jsonl")).hexdigest
        },
        entries: entries
      }
      File.write(output_path, JSON.pretty_generate(document), mode: "w:UTF-8")
      { output_path: File.expand_path(output_path), entry_count: entries.length, candidate_count: entries.sum { |row| row.fetch(:candidates).length }, network_call_performed: false }
    rescue Errno::ENOENT, CSV::MalformedCSVError, JSON::ParserError, KeyError => e
      raise DataError.new("Selection input source is invalid", details: { error: e.class.name, results_dir: @results_dir })
    end

    private

    def read_jsonl(filename)
      File.readlines(path(filename), encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def path(filename)
      File.join(@results_dir, filename)
    end

    def validate_entries!(entries)
      unless entries.length == 36 && entries.all? { |row| row.fetch(:candidates).length == TOP_N }
        raise DataError.new("Selection input must contain 36 entries with Top 5 candidates")
      end
    end
  end
end
