# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "yaml"

module AiLineSelection
  class AbstractionPreliminaryReviewer
    FATAL_FLAGS = %w[
      new_quantity new_person new_object new_event new_causality
      diagnosis fixed_emotion_or_personality unnecessary_proper_noun
    ].freeze
    QUALITY_FLAGS = (FATAL_FLAGS + %w[excessive_concrete meaning_loss]).freeze

    def initialize(configuration:, results_dir:, judgments_path:, export_path: nil, repetitions_export_path: nil)
      @configuration = configuration
      @results_dir = File.expand_path(results_dir)
      @judgments_path = File.expand_path(judgments_path)
      @export_path = export_path && File.expand_path(export_path)
      @repetitions_export_path = repetitions_export_path && File.expand_path(repetitions_export_path)
    end

    def call
      summary = read_json("summary.json")
      judgments = YAML.safe_load_file(@judgments_path, permitted_classes: [], aliases: false)
      records = read_jsonl("provider_outputs.jsonl")
      validate!(summary, judgments, records)
      items = representative_items(records)
      reviewed = items.map { |item| review_item(item, judgments) }
      review_summary = build_summary(summary, judgments, reviewed)
      write_json("preliminary_review_summary.json", review_summary)
      update_comparison_summary(summary, review_summary)
      export_abstractions(summary, judgments, reviewed) if @export_path
      export_repetitions(summary, judgments, reviewed, records) if @repetitions_export_path
      review_summary.merge(
        summary_file: File.join(@results_dir, "preliminary_review_summary.json"),
        export_file: @export_path,
        repetitions_export_file: @repetitions_export_path
      ).compact
    rescue Errno::ENOENT, Psych::Exception, JSON::ParserError, KeyError => e
      raise DataError.new(
        "Abstraction preliminary review input is invalid",
        details: { error_class: e.class.name, results_dir: @results_dir }
      )
    end

    private

    def validate!(summary, judgments, records)
      unless summary.fetch("completed") && summary.fetch("operation") == judgments.fetch("comparison_version").tr("-", "_")
        raise DataError.new("Abstraction comparison version does not match judgments")
      end
      unless judgments.fetch("all_items_reviewed") == true && judgments.fetch("judge") == "codex_preliminary"
        raise DataError.new("Abstraction judgments are not a complete Codex preliminary review")
      end
      expected = summary.fetch("item_count") * summary.fetch("repetitions")
      raise DataError.new("Abstraction output count is incomplete") unless records.length == expected

      ids = records.map { |record| record.fetch("item_id") }.uniq
      unknown = override_ids(judgments) - ids
      raise DataError.new("Abstraction judgments contain unknown IDs", details: { ids: unknown }) unless unknown.empty?
    end

    def override_ids(judgments)
      %w[candidate_overrides baseline_overrides semantic_overrides].flat_map do |key|
        judgments.fetch(key, {}).keys
      end.uniq
    end

    def representative_items(records)
      records.select { |record| record.fetch("repetition") == 1 }.map do |record|
        record.slice("item_id", "source_type", "status", "model", "abstraction")
      end
    end

    def review_item(item, judgments)
      id = item.fetch("item_id")
      candidate = judgment_for(judgments, "candidate", id)
      baseline = judgment_for(judgments, "baseline", id)
      semantic = semantic_judgment(judgments, id)
      {
        item: item,
        candidate: candidate,
        baseline: baseline,
        semantic: semantic
      }
    end

    def judgment_for(judgments, side, id)
      defaults = judgments.fetch("defaults").fetch(side)
      override = judgments.fetch("#{side}_overrides", {}).fetch(id, {})
      merged = deep_merge(defaults, override)
      usability = Integer(merged.fetch("usability"))
      raise DataError.new("Invalid abstraction usability", details: { id: id, side: side }) unless usability.between?(1, 3)

      flags = QUALITY_FLAGS.to_h { |flag| [flag, merged.fetch(flag, false) == true] }
      {
        usability: usability,
        abstraction_level_match: merged.fetch("abstraction_level_match") == true,
        flags: flags,
        confidence: merged.fetch("confidence", judgments.dig("defaults", "confidence") || "high"),
        reason: merged.fetch("reason", "")
      }
    end

    def semantic_judgment(judgments, id)
      defaults = judgments.fetch("defaults").fetch("semantic")
      override = judgments.fetch("semantic_overrides", {}).fetch(id, {})
      merged = deep_merge(defaults, override)
      {
        equivalent: merged.fetch("equivalent") == true,
        confidence: merged.fetch("confidence", judgments.dig("defaults", "confidence") || "high"),
        reason: merged.fetch("reason", "")
      }
    end

    def build_summary(comparison, judgments, reviewed)
      candidate = quality_summary(reviewed.map { |item| item.fetch(:candidate) })
      baseline = quality_summary(reviewed.map { |item| item.fetch(:baseline) })
      equivalent = reviewed.count { |item| item.dig(:semantic, :equivalent) }
      semantic_confidences = reviewed.map { |item| item.dig(:semantic, :confidence) }.tally.sort.to_h
      low_confidence_ids = reviewed.filter_map do |item|
        confidences = [
          item.dig(:candidate, :confidence),
          item.dig(:baseline, :confidence),
          item.dig(:semantic, :confidence)
        ]
        item.dig(:item, "item_id") if confidences.include?("low")
      end
      fatal_ids = reviewed.filter_map do |item|
        flags = item.dig(:candidate, :flags)
        item.dig(:item, "item_id") if FATAL_FLAGS.any? { |flag| flags.fetch(flag) }
      end
      semantic_rate = ratio(equivalent, reviewed.length)
      {
        status: "complete",
        judge: judgments.fetch("judge"),
        methodology: {
          all_items_reviewed: true,
          provider_and_condition_hidden_until_item_review_complete: true,
          candidate_repetition: 1,
          remaining_repetitions_used_for_semantic_equivalence: true,
          embedding_cosine_used_for_triage_only: true
        },
        item_count: reviewed.length,
        candidate: candidate,
        baseline: baseline,
        semantic_equivalence: {
          equivalent_items: equivalent,
          total_items: reviewed.length,
          rate: semantic_rate,
          non_equivalent_item_ids: reviewed.reject { |item| item.dig(:semantic, :equivalent) }
                                           .map { |item| item.dig(:item, "item_id") },
          confidence_counts: semantic_confidences
        },
        human_review_required_item_ids: (low_confidence_ids + fatal_ids).uniq.sort,
        human_review_required_count: (low_confidence_ids + fatal_ids).uniq.length,
        adoption_criteria: {
          initial_schema_success_at_least_99_percent: comparison.dig("provider", "first_attempt_schema_success_rate") >= 0.99,
          retry_schema_success_100_percent: comparison.dig("provider", "executions") ==
            comparison.fetch("item_count") * comparison.fetch("repetitions"),
          new_facts_zero: FATAL_FLAGS.first(5).all? { |flag| candidate.dig(:flag_counts, flag).zero? },
          diagnosis_fixed_state_and_proper_noun_zero: FATAL_FLAGS.drop(5).all? do |flag|
            candidate.dig(:flag_counts, flag).zero?
          end,
          blind_usability_at_least_90_percent: candidate.fetch(:usability_two_or_higher_rate) >= 0.90,
          semantic_equivalence_at_least_85_percent: semantic_rate >= 0.85,
          eligible_for_embedding_comparison: candidate.fetch(:usability_two_or_higher_rate) >= 0.90 &&
            semantic_rate >= 0.85 && FATAL_FLAGS.all? { |flag| candidate.dig(:flag_counts, flag).zero? }
        }
      }
    end

    def quality_summary(items)
      usable = items.count { |item| item.fetch(:usability) >= 2 }
      {
        evaluated_items: items.length,
        usability_average: average(items.sum { |item| item.fetch(:usability) }, items.length),
        usability_distribution: (1..3).to_h { |score| [score.to_s, items.count { |item| item.fetch(:usability) == score }] },
        usability_two_or_higher_rate: ratio(usable, items.length),
        abstraction_level_match_rate: ratio(items.count { |item| item.fetch(:abstraction_level_match) }, items.length),
        flag_counts: QUALITY_FLAGS.to_h do |flag|
          [flag, items.count { |item| item.dig(:flags, flag) }]
        end,
        confidence_counts: items.map { |item| item.fetch(:confidence) }.tally.sort.to_h
      }
    end

    def update_comparison_summary(comparison, review_summary)
      comparison["human_evaluation_pending"] = false
      comparison["codex_preliminary_evaluation"] = {
        "status" => "complete",
        "summary_file" => File.join(@results_dir, "preliminary_review_summary.json"),
        "human_review_required_count" => review_summary.fetch(:human_review_required_count)
      }
      criteria = review_summary.fetch(:adoption_criteria)
      comparison["adoption_criteria"]["semantic_equivalence_at_least_85_percent"] =
        criteria.fetch(:semantic_equivalence_at_least_85_percent)
      comparison["adoption_criteria"]["semantic_equivalence_pending"] = false
      comparison["adoption_criteria"]["human_quality_pending"] = false
      comparison["adoption_criteria"]["eligible_for_embedding_comparison"] =
        criteria.fetch(:eligible_for_embedding_comparison)
      write_json("summary.json", comparison)
    end

    def export_abstractions(comparison, judgments, reviewed)
      directory = File.dirname(@export_path)
      FileUtils.mkdir_p(directory)
      payload = {
        "version" => 1,
        "source" => "synthetic",
        "comparison_version" => judgments.fetch("comparison_version"),
        "prompt_sha256" => read_json("manifest.json").fetch("prompt_sha256"),
        "schema_sha256" => read_json("manifest.json").fetch("schema_sha256"),
        "entry_data_sha256" => read_json("manifest.json").fetch("entry_data_sha256"),
        "line_data_sha256" => read_json("manifest.json").fetch("line_data_sha256"),
        "provider" => comparison.dig("provider", "name"),
        "model" => comparison.dig("provider", "model"),
        "representative_repetition" => 1,
        "review" => {
          "judge" => judgments.fetch("judge"),
          "status" => "complete",
          "human_review_required_count" => 0
        },
        "abstractions" => reviewed.map do |review|
          item = review.fetch(:item)
          {
            "id" => item.fetch("item_id"),
            "source_type" => item.fetch("source_type"),
            "source_status" => item.fetch("status"),
            "abstraction" => item.fetch("abstraction"),
            "review_status" => "codex_preliminary",
            "usability" => review.dig(:candidate, :usability)
          }
        end
      }
      File.write(@export_path, YAML.dump(payload), mode: "w:UTF-8")
    end

    def export_repetitions(comparison, judgments, reviewed, records)
      FileUtils.mkdir_p(File.dirname(@repetitions_export_path))
      reviews_by_id = reviewed.to_h { |review| [review.dig(:item, "item_id"), review] }
      grouped_records = records.group_by { |record| record.fetch("item_id") }
      manifest_path = File.join(@results_dir, "manifest.json")
      manifest = read_json("manifest.json")
      payload = {
        "version" => 1,
        "source" => "synthetic",
        "comparison_version" => judgments.fetch("comparison_version"),
        "prompt_sha256" => manifest.fetch("prompt_sha256"),
        "schema_sha256" => manifest.fetch("schema_sha256"),
        "entry_data_sha256" => manifest.fetch("entry_data_sha256"),
        "line_data_sha256" => manifest.fetch("line_data_sha256"),
        "source_manifest_sha256" => Digest::SHA256.file(manifest_path).hexdigest,
        "provider" => comparison.dig("provider", "name"),
        "model" => comparison.dig("provider", "model"),
        "repetitions" => comparison.fetch("repetitions"),
        "line_index_repetition" => 1,
        "review" => {
          "judge" => judgments.fetch("judge"),
          "status" => "complete",
          "human_review_required_count" => 0
        },
        "items" => reviewed.map do |review|
          item = review.fetch(:item)
          id = item.fetch("item_id")
          repetitions = grouped_records.fetch(id).sort_by { |record| record.fetch("repetition") }.map do |record|
            {
              "repetition" => record.fetch("repetition"),
              "abstraction" => record.fetch("abstraction")
            }
          end
          {
            "id" => id,
            "source_type" => item.fetch("source_type"),
            "source_status" => item.fetch("status"),
            "review_status" => "codex_preliminary",
            "usability" => reviews_by_id.fetch(id).dig(:candidate, :usability),
            "repetitions" => repetitions
          }
        end
      }
      File.write(@repetitions_export_path, YAML.dump(payload), mode: "w:UTF-8")
    end

    def read_json(filename)
      JSON.parse(File.read(File.join(@results_dir, filename), encoding: "UTF-8"))
    end

    def read_jsonl(filename)
      File.readlines(File.join(@results_dir, filename), encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def write_json(filename, value)
      File.write(File.join(@results_dir, filename), JSON.pretty_generate(value), mode: "w:UTF-8")
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, old_value, new_value|
        old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
      end
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count)
      return 0.0 if count.zero?

      (total.to_f / count).round(4)
    end
  end
end
