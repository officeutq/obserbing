# frozen_string_literal: true

require "csv"
require "digest"
require "yaml"

module AiLineSelection
  class Bv2LightweightSelectorComparison
    VERSION = "b-v2-lightweight-selector-comparison-v1"

    def initialize(configuration:, criteria_path: nil)
      @configuration = configuration
      @criteria_path = File.expand_path(
        criteria_path || File.join(configuration.root_dir, "data", "evaluations", "b_v2_lightweight_selector_criteria_v1.yml")
      )
      @criteria = YAML.safe_load_file(@criteria_path, permitted_classes: [], aliases: false)
    end

    def plan
      validate_criteria!
      pair_path = source_path("pair_similarities")
      rows = CSV.read(pair_path, headers: true, encoding: "UTF-8")
      unique = rows.map { |row| row.values_at("entry_id", "repetition", "line_id") }.uniq
      unless rows.length == 10_368 && unique.length == 10_368
        raise DataError.new("Lightweight selector comparison requires 10,368 unique pair rows")
      end

      {
        version: VERSION,
        issue: 61,
        network_call_performed: false,
        external_api_calls: 0,
        quality_aggregation_performed: false,
        pair_count: rows.length,
        outcome_slots: rows.map { |row| [row.fetch("entry_id"), row.fetch("repetition")] }.uniq.length,
        line_count: rows.map { |row| row.fetch("line_id") }.uniq.length,
        bands: @criteria.fetch("bands"),
        selectors: @criteria.fetch("selectors").map { |row| row.fetch("id") },
        weight_bounds: @criteria.fetch("weight_bounds"),
        overfitting_control: @criteria.fetch("overfitting_control").slice("method", "parameter_tuning_from_labels", "folds"),
        label_usage: "evaluation_only",
        prohibited_selector_features: @criteria.dig("selection_contract", "prohibited_features"),
        source_hashes_verified: verified_source_hashes,
        criteria_sha256: canonical_sha256(@criteria_path),
        ready_for_offline_comparison: true
      }
    rescue Errno::ENOENT, CSV::MalformedCSVError, Psych::Exception, KeyError => e
      raise DataError.new(
        "B-v2 lightweight selector criteria or source is invalid",
        details: { error: e.class.name, message: e.message, source_line: e.backtrace&.first }
      )
    end

    private

    def validate_criteria!
      unless @criteria.fetch("version") == "b-v2-lightweight-selector-criteria-v1" &&
             @criteria.fetch("frozen_before_quality_aggregation") &&
             Integer(@criteria.fetch("external_api_calls")).zero?
        raise DataError.new("Lightweight selector criteria header is invalid")
      end
      ids = @criteria.fetch("selectors").map { |row| row.fetch("id") }
      unless ids == Bv2LightweightSelector::STRATEGIES
        raise DataError.new("Criteria selector order does not match implementation", details: { expected: Bv2LightweightSelector::STRATEGIES, actual: ids })
      end
      bounds = @criteria.fetch("weight_bounds")
      unless Float(bounds.fetch("minimum")) == Bv2LightweightSelector::MIN_WEIGHT &&
             Float(bounds.fetch("maximum")) == Bv2LightweightSelector::MAX_WEIGHT
        raise DataError.new("Criteria weight bounds do not match implementation")
      end
      verified_source_hashes
    end

    def verified_source_hashes
      @criteria.fetch("sources").to_h do |name, source|
        path = File.join(@configuration.root_dir, source.fetch("path"))
        expected = source.fetch("canonical_lf_sha256")
        actual = canonical_sha256(path)
        unless actual == expected
          raise DataError.new("Lightweight selector source hash mismatch", details: { source: name, expected: expected, actual: actual })
        end
        [name, actual]
      end
    end

    def source_path(name)
      File.join(@configuration.root_dir, @criteria.dig("sources", name, "path"))
    end

    def canonical_sha256(path)
      Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n"))
    end
  end
end
