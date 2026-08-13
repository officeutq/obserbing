# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
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

    def prepare(output_dir:)
      preflight = plan
      output_dir = File.expand_path(output_dir)
      FileUtils.mkdir_p(output_dir)
      rows = CSV.read(source_path("pair_similarities"), headers: true, encoding: "UTF-8").map(&:to_h)
      slots = rows.group_by { |row| [row.fetch("entry_id"), Integer(row.fetch("repetition"))] }
      data = DataLoader.new(@configuration)
      @entries = data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = data.lines.select { |line| line.fetch("status") == "approved" }.to_h { |line| [line.fetch("id"), line] }
      @guard = Bv2PolicyGuard.new(configuration: @configuration)

      selections_path = File.join(output_dir, "b_v2_lightweight_selector_selections_v1.csv")
      timing = Hash.new { |hash, key| hash[key] = { elapsed_ms: 0.0, calls: 0 } }
      selected_pairs = Hash.new { |hash, key| hash[key] = { occurrences: 0, selectors: {}, bands: {} } }
      CSV.open(selections_path, "w:UTF-8", write_headers: true, headers: selection_headers) do |csv|
        @criteria.fetch("bands").each do |band_name, band|
          @criteria.fetch("selectors").each do |selector_spec|
            selector_id = selector_spec.fetch("id")
            selector = Bv2LightweightSelector.new(
              strategy: selector_id, a_min: band.fetch("a_min"), s_max: band.fetch("s_max")
            )
            slots.sort.each do |(entry_id, repetition), pair_rows|
              candidates = eligible_candidates(entry_id, pair_rows, band)
              seed = Bv2Selector.seed(
                base_seed: @configuration.random_seed, entry_id: entry_id, repetition: repetition
              )
              started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              selection = selector.select(candidates: candidates, seed: seed)
              elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
              repeated = selector.select(candidates: candidates, seed: seed)
              reproducible = selection == repeated
              selected = candidates.find { |candidate| candidate.fetch("line_id") == selection.fetch(:line_id) }
              line_id = selection.fetch(:line_id)
              if line_id
                pair = selected_pairs["#{entry_id}/#{line_id}"]
                pair[:occurrences] += 1
                pair[:selectors][selector_id] = true
                pair[:bands][band_name] = true
              end
              timing[[band_name, selector_id]][:elapsed_ms] += elapsed_ms
              timing[[band_name, selector_id]][:calls] += 1
              csv << [
                band_name, band.fetch("a_min"), band.fetch("s_max"), band.fetch("top_n"), selector_id,
                entry_id, repetition, candidates.length, selection.fetch(:status), line_id, seed,
                reproducible, selection.fetch(:selected_weight), selection.fetch(:minimum_weight),
                selection.fetch(:maximum_weight), selection.fetch(:maximum_weight_ratio),
                selected && selected.fetch("abstraction_similarity"),
                selected && selected.fetch("surface_similarity"),
                selected && selected.fetch("domain_primary")
              ]
            end
          end
        end
      end

      reproduction = verify_uniform_reproduction(selections_path)
      unless reproduction.values.all? { |value| value.fetch(:exact) }
        raise DataError.new("Issue 59 uniform selections were not exactly reproduced", details: reproduction)
      end
      review_path = File.join(output_dir, "b_v2_lightweight_selector_new_pair_review_v1.csv")
      review = write_missing_review(review_path, selected_pairs)
      timing_path = File.join(output_dir, "b_v2_lightweight_selector_timing_v1.json")
      timing_rows = timing.map do |(band, selector), value|
        {
          band: band, selector: selector, calls: value.fetch(:calls),
          elapsed_milliseconds: value.fetch(:elapsed_ms).round(6),
          milliseconds_per_selection: (value.fetch(:elapsed_ms) / value.fetch(:calls)).round(6)
        }
      end.sort_by { |row| [row.fetch(:band), row.fetch(:selector)] }
      File.write(timing_path, JSON.pretty_generate(timing_rows), mode: "w:UTF-8")
      manifest = {
        version: VERSION,
        issue: 61,
        completed_mechanical_selection: true,
        quality_aggregation_performed: false,
        network_call_performed: false,
        external_api_calls: 0,
        outcome_slots_per_selector_band: slots.length,
        band_count: @criteria.fetch("bands").length,
        selector_count: @criteria.fetch("selectors").length,
        selection_row_count: slots.length * @criteria.fetch("bands").length * @criteria.fetch("selectors").length,
        selected_unique_pair_count: selected_pairs.length,
        new_pair_review: review,
        uniform_reproduction: reproduction,
        selector_input_includes_quality_labels: false,
        source_hashes: preflight.fetch(:source_hashes_verified),
        artifact_hashes: {
          selections_sha256: canonical_sha256(selections_path),
          missing_review_sha256: canonical_sha256(review_path),
          timing_sha256: canonical_sha256(timing_path)
        }
      }
      manifest_path = File.join(output_dir, "b_v2_lightweight_selector_manifest_v1.json")
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w:UTF-8")
      manifest.merge(output_dir: output_dir, manifest_path: manifest_path)
    end

    def evaluate(output_dir:)
      output_dir = File.expand_path(output_dir)
      selections_path = File.join(output_dir, "b_v2_lightweight_selector_selections_v1.csv")
      manifest_path = File.join(output_dir, "b_v2_lightweight_selector_manifest_v1.json")
      manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      unless manifest.fetch("completed_mechanical_selection")
        raise DataError.new("Mechanical selector evidence must be complete before aggregation")
      end

      setup_fixed_data
      labels = load_labels
      selections = CSV.read(selections_path, headers: true, encoding: "UTF-8")
      selected_pair_ids = selections.filter_map do |row|
        line_id = blank_to_nil(row.fetch("selected_line_id"))
        "#{row.fetch('entry_id')}/#{line_id}" if line_id
      end.uniq
      missing = selected_pair_ids.reject { |pair_id| labels.key?(pair_id) }
      unless missing.empty?
        raise DataError.new("Selected pairs require Codex provisional review before aggregation", details: { pair_ids: missing })
      end

      candidate_sets = build_candidate_sets
      timing = JSON.parse(File.read(File.join(output_dir, "b_v2_lightweight_selector_timing_v1.json"), encoding: "UTF-8"))
                    .to_h { |row| [[row.fetch("band"), row.fetch("selector")], row] }
      summaries = selections.group_by { |row| [row.fetch("band"), row.fetch("selector")] }.map do |(band, selector), rows|
        summarize_rows(rows, labels, candidate_sets.fetch(band), timing.fetch([band, selector]))
      end.sort_by { |row| [row.fetch(:band), row.fetch(:selector)] }
      validate_uniform_references!(summaries)

      rankings = @criteria.fetch("bands").keys.to_h do |band|
        [band, rank_summaries(summaries.select { |row| row.fetch(:band) == band }).map { |row| row.fetch(:selector) }]
      end
      primary_ranking = rankings.fetch("primary")
      overall_best = primary_ranking.first
      best_non_uniform = primary_ranking.find { |selector| selector != "uniform" }
      cross_validation = build_cross_validation(selections, labels, candidate_sets, best_non_uniform)
      low_confidence = paired_low_confidence_sensitivity(selections, labels, best_non_uniform)
      robustness = build_robustness(rankings)
      diagnosis = diagnose(
        summaries, rankings, cross_validation, low_confidence,
        best_non_uniform, selected_pair_ids.length, missing.length
      )

      blind = build_blind_packet(
        output_dir, selections, labels, primary_ranking.first(3)
      )
      result = {
        version: VERSION,
        issue: 61,
        completed: true,
        post_hoc_offline_comparison: true,
        generalization_proven: false,
        network_call_performed: false,
        external_api_calls: 0,
        selector_input_includes_quality_labels: false,
        selected_pair_label_coverage_rate: ratio(selected_pair_ids.length - missing.length, selected_pair_ids.length),
        bands: @criteria.fetch("bands"),
        selectors: Bv2LightweightSelector::STRATEGIES,
        summaries: summaries,
        rankings: rankings,
        overall_best_selector: overall_best,
        best_non_uniform_selector: best_non_uniform,
        robustness: robustness,
        cross_validation: cross_validation,
        low_confidence_sensitivity: low_confidence,
        blind_human_review: blind.reject { |key, _value| %i[packet_path mapping_path].include?(key) },
        diagnosis: diagnosis,
        changes_existing_gate_a_or_epic_40_decision: false,
        limitations: [
          "The same fixed 36 synthetic Entries are reused in a post-hoc analysis",
          "Six-fold Entry cross-validation checks stability but does not prove generalization to new user text",
          "Codex provisional reflective-distance labels are evaluation-only and require blind human confirmation before adoption",
          "Known-acceptable opportunity is a lower bound because not every eligible Entry/Line pair has a quality label"
        ],
        source_hashes: plan.fetch(:source_hashes_verified).merge(
          "criteria" => canonical_sha256(@criteria_path),
          "selections" => canonical_sha256(selections_path)
        )
      }
      result_path = File.join(output_dir, "b_v2_lightweight_selector_comparison_v1.json")
      File.write(result_path, JSON.pretty_generate(result), mode: "w:UTF-8")
      cv_path = File.join(output_dir, "b_v2_lightweight_selector_cross_validation_v1.json")
      File.write(cv_path, JSON.pretty_generate(cross_validation), mode: "w:UTF-8")
      conclusion_path = File.join(output_dir, "b_v2_lightweight_selector_conclusion_v1.json")
      File.write(conclusion_path, JSON.pretty_generate(diagnosis), mode: "w:UTF-8")

      manifest["quality_aggregation_performed"] = true
      manifest["selected_pair_label_coverage_rate"] = result.fetch(:selected_pair_label_coverage_rate)
      manifest["diagnosis"] = diagnosis.fetch(:value)
      manifest["artifact_hashes"].merge!(
        "comparison_sha256" => canonical_sha256(result_path),
        "cross_validation_sha256" => canonical_sha256(cv_path),
        "conclusion_sha256" => canonical_sha256(conclusion_path),
        "blind_packet_sha256" => canonical_sha256(blind.fetch(:packet_path)),
        "blind_mapping_sha256" => canonical_sha256(blind.fetch(:mapping_path))
      )
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w:UTF-8")
      {
        completed: true,
        overall_best_selector: overall_best,
        best_non_uniform_selector: best_non_uniform,
        diagnosis: diagnosis.fetch(:value),
        result_path: result_path,
        blind_packet_path: blind.fetch(:packet_path),
        external_api_calls: 0
      }
    end

    private

    def setup_fixed_data
      data = DataLoader.new(@configuration)
      @entries = data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = data.lines.select { |line| line.fetch("status") == "approved" }.to_h { |line| [line.fetch("id"), line] }
      @guard = Bv2PolicyGuard.new(configuration: @configuration)
      @pair_rows = CSV.read(source_path("pair_similarities"), headers: true, encoding: "UTF-8").map(&:to_h)
                       .group_by { |row| [row.fetch("entry_id"), Integer(row.fetch("repetition"))] }
    end

    def load_labels
      CSV.read(source_path("pair_judgments"), headers: true, encoding: "UTF-8").to_h do |row|
        [row.fetch("pair_id"), {
          "acceptable" => boolean(row.fetch("acceptable")),
          "distance" => row.fetch("distance"),
          "relation_type" => row.fetch("relation_type"),
          "confidence" => row.fetch("confidence"),
          "low_confidence" => row.fetch("confidence") == "low",
          "judge" => row.fetch("judge"),
          "provisional" => boolean(row.fetch("provisional"))
        }]
      end
    end

    def build_candidate_sets
      @criteria.fetch("bands").to_h do |band_name, band|
        [band_name, @pair_rows.to_h do |(entry_id, repetition), rows|
          [[entry_id, repetition], eligible_candidates(entry_id, rows, band)]
        end]
      end
    end

    def summarize_rows(rows, labels, candidate_sets, timing)
      outcomes = rows.map { |row| labeled_outcome(row, labels) }
      acceptable = outcomes.count { |row| row.fetch(:acceptable) }
      all_three = outcomes.group_by { |row| row.fetch(:entry_id) }.count do |_entry_id, entry_rows|
        entry_rows.length == 3 && entry_rows.all? { |row| row.fetch(:acceptable) }
      end
      opportunity = known_acceptable_opportunity(rows, labels, candidate_sets)
      line_counts = outcomes.filter_map { |row| row.fetch(:line_id) }.tally
      selected_count = line_counts.values.sum
      entropy = if selected_count.zero?
                  0.0
                else
                  raw = line_counts.values.sum do |count|
                    probability = count.to_f / selected_count
                    -probability * Math.log(probability)
                  end
                  (raw / Math.log(@lines.length)).round(6)
                end
      low = outcomes.count { |row| row.fetch(:low_confidence) }
      {
        band: rows.first.fetch("band"),
        selector: rows.first.fetch("selector"),
        outcome_count: outcomes.length,
        selected_count: selected_count,
        semantic_silence_count: outcomes.count { |row| row.fetch(:distance) == "semantic_silence" },
        semantic_silence_rate: ratio(outcomes.count { |row| row.fetch(:distance) == "semantic_silence" }, outcomes.length),
        acceptable_count: acceptable,
        acceptable_rate: ratio(acceptable, outcomes.length),
        all_three_repetitions_acceptable_entry_count: all_three,
        all_three_repetitions_acceptable_entry_rate: ratio(all_three, outcomes.map { |row| row.fetch(:entry_id) }.uniq.length),
        distance_counts: outcomes.map { |row| row.fetch(:distance) }.tally.sort.to_h,
        relation_type_counts: outcomes.map { |row| row.fetch(:relation_type) }.tally.sort.to_h,
        analogical_transfer_count: outcomes.count { |row| row.fetch(:relation_type) == "analogical_transfer" },
        known_acceptable_opportunity: opportunity,
        seed_reproducibility_rate: ratio(rows.count { |row| boolean(row.fetch("reproducible")) }, rows.length),
        selected_unique_line_count: line_counts.length,
        maximum_line_selection_count: line_counts.values.max || 0,
        maximum_line_share: ratio(line_counts.values.max || 0, selected_count),
        normalized_selection_entropy: entropy,
        low_confidence_occurrence_count: low,
        low_confidence_lower_acceptable_count: outcomes.count { |row| row.fetch(:acceptable) && !row.fetch(:low_confidence) },
        low_confidence_upper_acceptable_count: outcomes.count { |row| row.fetch(:acceptable) || row.fetch(:low_confidence) },
        computation: {
          elapsed_milliseconds: Float(timing.fetch("elapsed_milliseconds")),
          milliseconds_per_selection: Float(timing.fetch("milliseconds_per_selection")),
          external_api_calls: 0
        }
      }
    end

    def labeled_outcome(row, labels)
      entry_id = row.fetch("entry_id")
      repetition = Integer(row.fetch("repetition"))
      line_id = blank_to_nil(row.fetch("selected_line_id"))
      unless line_id
        return {
          entry_id: entry_id, repetition: repetition, line_id: nil,
          acceptable: false, distance: "semantic_silence", relation_type: "semantic_silence",
          confidence: "not_applicable", low_confidence: false
        }
      end

      label = labels.fetch("#{entry_id}/#{line_id}")
      {
        entry_id: entry_id, repetition: repetition, line_id: line_id,
        acceptable: label.fetch("acceptable"), distance: label.fetch("distance"),
        relation_type: label.fetch("relation_type"), confidence: label.fetch("confidence"),
        low_confidence: label.fetch("low_confidence")
      }
    end

    def known_acceptable_opportunity(rows, labels, candidate_sets)
      opportunities = 0
      missed = 0
      labeled_occurrences = 0
      eligible_occurrences = 0
      rows.each do |row|
        slot = [row.fetch("entry_id"), Integer(row.fetch("repetition"))]
        candidates = candidate_sets.fetch(slot)
        eligible_occurrences += candidates.length
        known = candidates.filter_map { |candidate| labels["#{row.fetch('entry_id')}/#{candidate.fetch('line_id')}"] }
        labeled_occurrences += known.length
        next unless known.any? { |label| label.fetch("acceptable") }

        opportunities += 1
        line_id = blank_to_nil(row.fetch("selected_line_id"))
        selected = line_id && labels.fetch("#{row.fetch('entry_id')}/#{line_id}")
        missed += 1 unless selected && selected.fetch("acceptable")
      end
      {
        eligible_candidate_occurrences: eligible_occurrences,
        labeled_eligible_candidate_occurrences: labeled_occurrences,
        labeled_eligible_coverage_rate: ratio(labeled_occurrences, eligible_occurrences),
        slots_with_known_acceptable_candidate: opportunities,
        missed_known_acceptable_count: missed,
        missed_known_acceptable_rate: ratio(missed, opportunities),
        lower_bound: true
      }
    end

    def validate_uniform_references!(summaries)
      @criteria.fetch("bands").each do |band_name, band|
        summary = summaries.find { |row| row.fetch(:band) == band_name && row.fetch(:selector) == "uniform" }
        reference = band.fetch("issue_59_uniform_reference")
        checks = {
          acceptable_count: [summary.fetch(:acceptable_count), Integer(reference.fetch("acceptable_count"))],
          acceptable_rate: [summary.fetch(:acceptable_rate), Float(reference.fetch("acceptable_rate"))],
          slots_with_known_acceptable_candidate: [summary.dig(:known_acceptable_opportunity, :slots_with_known_acceptable_candidate), Integer(reference.fetch("slots_with_known_acceptable_candidate"))],
          missed_known_acceptable_count: [summary.dig(:known_acceptable_opportunity, :missed_known_acceptable_count), Integer(reference.fetch("missed_known_acceptable_count"))]
        }
        failures = checks.select { |_name, values| (values.fetch(0).to_f - values.fetch(1).to_f).abs > 0.000001 }
        unless failures.empty?
          raise DataError.new("Uniform quality reference mismatch", details: { band: band_name, failures: failures })
        end
      end
    end

    def rank_summaries(summaries)
      summaries.sort_by do |row|
        [
          -row.fetch(:acceptable_rate),
          row.dig(:known_acceptable_opportunity, :missed_known_acceptable_rate),
          -row.fetch(:all_three_repetitions_acceptable_entry_rate),
          row.fetch(:selector)
        ]
      end
    end

    def build_cross_validation(selections, labels, candidate_sets, candidate_selector)
      folds = @criteria.dig("overfitting_control", "folds")
      reports = folds.map do |fold_name, holdout_entries|
        dev_entries = @entries.keys - holdout_entries
        band_reports = @criteria.fetch("bands").keys.to_h do |band|
          band_rows = selections.select { |row| row.fetch("band") == band }
          dev_summaries = Bv2LightweightSelector::STRATEGIES.map do |selector|
            subset_summary(band_rows, selector, dev_entries, labels, candidate_sets.fetch(band))
          end
          holdout_summaries = Bv2LightweightSelector::STRATEGIES.map do |selector|
            subset_summary(band_rows, selector, holdout_entries, labels, candidate_sets.fetch(band))
          end
          ranking = rank_summaries(dev_summaries).map { |row| row.fetch(:selector) }
          candidate = holdout_summaries.find { |row| row.fetch(:selector) == candidate_selector }
          uniform = holdout_summaries.find { |row| row.fetch(:selector) == "uniform" }
          [band, {
            dev_ranking: ranking,
            dev_winner: ranking.first,
            holdout_candidate_selector: candidate_selector,
            holdout_candidate_acceptable_rate: candidate.fetch(:acceptable_rate),
            holdout_uniform_acceptable_rate: uniform.fetch(:acceptable_rate),
            holdout_acceptable_gain_points: ((candidate.fetch(:acceptable_rate) - uniform.fetch(:acceptable_rate)) * 100).round(4),
            holdout_candidate_missed_count: candidate.dig(:known_acceptable_opportunity, :missed_known_acceptable_count),
            holdout_uniform_missed_count: uniform.dig(:known_acceptable_opportunity, :missed_known_acceptable_count),
            holdout_missed_count_reduction: uniform.dig(:known_acceptable_opportunity, :missed_known_acceptable_count) - candidate.dig(:known_acceptable_opportunity, :missed_known_acceptable_count)
          }]
        end
        { fold: fold_name, holdout_entries: holdout_entries, bands: band_reports }
      end
      primary = reports.map { |row| row.dig(:bands, "primary") }
      {
        method: @criteria.dig("overfitting_control", "method"),
        parameter_tuning_from_labels: false,
        candidate_selector: candidate_selector,
        folds: reports,
        primary_holdout_folds_with_positive_acceptable_gain: primary.count { |row| row.fetch(:holdout_acceptable_gain_points).positive? },
        primary_holdout_folds_with_nonworse_missed_count: primary.count { |row| row.fetch(:holdout_missed_count_reduction) >= 0 },
        primary_dev_winner_counts: primary.map { |row| row.fetch(:dev_winner) }.tally.sort.to_h,
        generalization_proven: false
      }
    end

    def subset_summary(rows, selector, entry_ids, labels, candidate_sets)
      selected = rows.select { |row| row.fetch("selector") == selector && entry_ids.include?(row.fetch("entry_id")) }
      summary = summarize_rows(
        selected, labels, candidate_sets,
        { "elapsed_milliseconds" => 0.0, "milliseconds_per_selection" => 0.0 }
      )
      summary.slice(
        :band, :selector, :outcome_count, :acceptable_count, :acceptable_rate,
        :all_three_repetitions_acceptable_entry_count, :all_three_repetitions_acceptable_entry_rate,
        :known_acceptable_opportunity
      )
    end

    def paired_low_confidence_sensitivity(selections, labels, selector)
      @criteria.fetch("bands").keys.to_h do |band|
        rows = selections.select { |row| row.fetch("band") == band }
        uniform = rows.select { |row| row.fetch("selector") == "uniform" }
                      .to_h { |row| [[row.fetch("entry_id"), row.fetch("repetition")], row] }
        candidate = rows.select { |row| row.fetch("selector") == selector }
        included = []
        candidate.each do |candidate_row|
          key = [candidate_row.fetch("entry_id"), candidate_row.fetch("repetition")]
          uniform_row = uniform.fetch(key)
          candidate_outcome = labeled_outcome(candidate_row, labels)
          uniform_outcome = labeled_outcome(uniform_row, labels)
          next if candidate_outcome.fetch(:low_confidence) || uniform_outcome.fetch(:low_confidence)

          included << [candidate_outcome, uniform_outcome]
        end
        candidate_acceptable = included.count { |pair| pair.fetch(0).fetch(:acceptable) }
        uniform_acceptable = included.count { |pair| pair.fetch(1).fetch(:acceptable) }
        [band, {
          selector: selector,
          included_non_low_confidence_slots: included.length,
          excluded_low_confidence_slots: 108 - included.length,
          candidate_acceptable_count: candidate_acceptable,
          uniform_acceptable_count: uniform_acceptable,
          acceptable_gain_count: candidate_acceptable - uniform_acceptable,
          acceptable_gain_points_on_included_slots: ((candidate_acceptable - uniform_acceptable).to_f / included.length * 100).round(4),
          gain_positive: candidate_acceptable > uniform_acceptable
        }]
      end
    end

    def build_robustness(rankings)
      primary = rankings.fetch("primary")
      neighbor = rankings.fetch("neighbor")
      {
        primary_ranking: primary,
        neighbor_ranking: neighbor,
        same_winner: primary.first == neighbor.first,
        primary_winner_neighbor_rank: neighbor.index(primary.first) + 1,
        spearman_rank_correlation: spearman(primary, neighbor)
      }
    end

    def spearman(left, right)
      positions = right.each_with_index.to_h { |selector, index| [selector, index + 1] }
      sum = left.each_with_index.sum { |selector, index| ((index + 1) - positions.fetch(selector))**2 }
      count = left.length
      (1.0 - ((6.0 * sum) / (count * ((count**2) - 1)))).round(6)
    end

    def diagnose(summaries, rankings, cross_validation, low_confidence, selector, selected_pair_count, missing_count)
      primary = summaries.find { |row| row.fetch(:band) == "primary" && row.fetch(:selector) == selector }
      primary_uniform = summaries.find { |row| row.fetch(:band) == "primary" && row.fetch(:selector) == "uniform" }
      neighbor = summaries.find { |row| row.fetch(:band) == "neighbor" && row.fetch(:selector) == selector }
      neighbor_uniform = summaries.find { |row| row.fetch(:band) == "neighbor" && row.fetch(:selector) == "uniform" }
      thresholds = @criteria.dig("diagnosis", "provisional_promising_if_all")
      checks = {
        primary_acceptable_gain_points: {
          observed: ((primary.fetch(:acceptable_rate) - primary_uniform.fetch(:acceptable_rate)) * 100).round(4),
          required: Float(thresholds.fetch("primary_acceptable_gain_points_at_least"))
        },
        primary_missed_reduction: {
          observed: primary_uniform.dig(:known_acceptable_opportunity, :missed_known_acceptable_count) - primary.dig(:known_acceptable_opportunity, :missed_known_acceptable_count),
          required: Integer(thresholds.fetch("primary_missed_known_acceptable_reduction_at_least"))
        },
        neighbor_acceptable_gain_points: {
          observed: ((neighbor.fetch(:acceptable_rate) - neighbor_uniform.fetch(:acceptable_rate)) * 100).round(4),
          required: Float(thresholds.fetch("neighbor_acceptable_gain_points_at_least"))
        },
        neighbor_missed_reduction: {
          observed: neighbor_uniform.dig(:known_acceptable_opportunity, :missed_known_acceptable_count) - neighbor.dig(:known_acceptable_opportunity, :missed_known_acceptable_count),
          required: Integer(thresholds.fetch("neighbor_missed_known_acceptable_reduction_at_least"))
        },
        winner_neighbor_rank: {
          observed: rankings.fetch("neighbor").index(selector) + 1,
          required_maximum: Integer(thresholds.fetch("winner_neighbor_rank_at_most"))
        },
        holdout_positive_gain_folds: {
          observed: cross_validation.fetch(:primary_holdout_folds_with_positive_acceptable_gain),
          required: Integer(thresholds.fetch("holdout_folds_with_positive_acceptable_gain_at_least"))
        },
        holdout_nonworse_missed_folds: {
          observed: cross_validation.fetch(:primary_holdout_folds_with_nonworse_missed_count),
          required: Integer(thresholds.fetch("holdout_folds_with_nonworse_missed_count_at_least"))
        },
        maximum_line_share_increase_points: {
          observed: ((primary.fetch(:maximum_line_share) - primary_uniform.fetch(:maximum_line_share)) * 100).round(4),
          required_maximum: Float(thresholds.fetch("maximum_line_share_not_over_uniform_by_points"))
        }
      }
      checks.each_value do |check|
        check[:pass] = if check.key?(:required)
                         check.fetch(:observed) >= check.fetch(:required)
                       else
                         check.fetch(:observed) <= check.fetch(:required_maximum)
                       end
      end
      evidence_complete = missing_count.zero? && selected_pair_count.positive? &&
                          summaries.all? { |row| row.fetch(:outcome_count) == 108 && row.fetch(:seed_reproducibility_rate) == 1.0 }
      provisional_promising = checks.values.all? { |check| check.fetch(:pass) }
      paired_positive = low_confidence.dig("primary", :gain_positive)
      value = if !evidence_complete
                "evidence_insufficient"
              elsif provisional_promising && !paired_positive
                "human_review_required"
              elsif provisional_promising
                "lightweight_selector_promising"
              else
                "selector_gain_insufficient"
              end
      {
        value: value,
        evaluated_selector: selector,
        evidence_complete: evidence_complete,
        provisional_promising: provisional_promising,
        paired_non_low_confidence_gain_positive: paired_positive,
        checks: checks,
        existing_gate_a_or_epic_40_changed: false,
        human_review_required_before_adoption: true,
        external_api_calls: 0
      }
    end

    def build_blind_packet(output_dir, selections, labels, top_selectors)
      primary = selections.select { |row| row.fetch("band") == "primary" && top_selectors.include?(row.fetch("selector")) }
      candidates = primary.group_by { |row| [row.fetch("entry_id"), Integer(row.fetch("repetition"))] }.filter_map do |slot, rows|
        line_ids = rows.filter_map { |row| blank_to_nil(row.fetch("selected_line_id")) }.uniq
        next if line_ids.length < 2

        label_rows = line_ids.map { |line_id| labels.fetch("#{slot.fetch(0)}/#{line_id}") }
        {
          slot: slot, rows: rows, line_ids: line_ids,
          acceptability_disagreement: label_rows.map { |label| label.fetch("acceptable") }.uniq.length > 1,
          contains_low_confidence: label_rows.any? { |label| label.fetch("low_confidence") },
          deterministic_order: Digest::SHA256.hexdigest("issue61|#{slot.join('|')}")
        }
      end
      chosen = candidates.sort_by do |row|
        [row.fetch(:acceptability_disagreement) ? 0 : 1, row.fetch(:contains_low_confidence) ? 0 : 1, -row.fetch(:line_ids).length, row.fetch(:deterministic_order)]
      end.first(Integer(@criteria.dig("blind_human_review", "target_case_count")))

      packet_path = File.join(output_dir, "b_v2_lightweight_selector_blind_human_review_v1.csv")
      mapping_path = File.join(output_dir, "b_v2_lightweight_selector_blind_mapping_v1.yml")
      packet_headers = %w[
        blind_case_id entry_text option_a_text option_a_acceptable option_b_text option_b_acceptable
        option_c_text option_c_acceptable overall_preference notes
      ]
      mappings = []
      CSV.open(packet_path, "w:UTF-8", write_headers: true, headers: packet_headers) do |csv|
        chosen.each_with_index do |item, index|
          case_id = format("S%03d", index + 1)
          entry_id, repetition = item.fetch(:slot)
          ordered_lines = item.fetch(:line_ids).sort_by { |line_id| Digest::SHA256.hexdigest("#{case_id}|#{line_id}") }
          options = ordered_lines.each_with_index.map do |line_id, option_index|
            blind_label = (65 + option_index).chr
            selecting_rows = item.fetch(:rows).select { |row| row.fetch("selected_line_id") == line_id }
            label = labels.fetch("#{entry_id}/#{line_id}")
            {
              "blind_label" => blind_label, "line_id" => line_id,
              "selectors" => selecting_rows.map { |row| row.fetch("selector") }.sort,
              "abstraction_similarity" => Float(selecting_rows.first.fetch("selected_abstraction_similarity")),
              "surface_similarity" => Float(selecting_rows.first.fetch("selected_surface_similarity")),
              "quality_label" => label
            }
          end
          texts = options.to_h { |option| [option.fetch("blind_label"), @lines.fetch(option.fetch("line_id")).fetch("text")] }
          csv << [
            case_id, @entries.fetch(entry_id).fetch("body"),
            texts["A"], nil, texts["B"], nil, texts["C"], nil, nil, nil
          ]
          mappings << {
            "blind_case_id" => case_id, "entry_id" => entry_id, "repetition" => repetition,
            "acceptability_disagreement" => item.fetch(:acceptability_disagreement),
            "contains_low_confidence" => item.fetch(:contains_low_confidence),
            "options" => options
          }
        end
      end
      mapping = {
        "version" => "b-v2-lightweight-selector-blind-mapping-v1",
        "issue" => 61,
        "do_not_distribute_with_blind_packet" => true,
        "hidden_fields" => @criteria.dig("blind_human_review", "hidden"),
        "top_selectors" => top_selectors,
        "cases" => mappings
      }
      File.write(mapping_path, YAML.dump(mapping), mode: "w:UTF-8")
      {
        target_case_count: Integer(@criteria.dig("blind_human_review", "target_case_count")),
        actual_case_count: chosen.length,
        top_selectors: top_selectors,
        acceptability_disagreement_case_count: chosen.count { |item| item.fetch(:acceptability_disagreement) },
        low_confidence_case_count: chosen.count { |item| item.fetch(:contains_low_confidence) },
        packet_contains_hidden_fields: false,
        human_review_completed: false,
        packet_path: packet_path,
        mapping_path: mapping_path
      }
    end

    def blank_to_nil(value)
      value.to_s.empty? ? nil : value
    end

    def boolean(value)
      case value
      when true, "true" then true
      when false, "false" then false
      else raise DataError.new("Invalid boolean value", details: { value: value })
      end
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(6)
    end

    def eligible_candidates(entry_id, rows, band)
      rows.sort_by { |row| [-Float(row.fetch("abstraction_similarity")), row.fetch("line_id")] }
          .first(Integer(band.fetch("top_n"))).filter_map do |row|
        next if Float(row.fetch("abstraction_similarity")) < Float(band.fetch("a_min"))
        next if Float(row.fetch("surface_similarity")) > Float(band.fetch("s_max"))

        line = @lines.fetch(row.fetch("line_id"))
        decision = @guard.evaluate(
          entry: @entries.fetch(entry_id), line: line,
          profile_version: Bv2IntegratedComparison::PROFILE_VERSION,
          embedding_version: Bv2IntegratedComparison::EMBEDDING_VERSION,
          history: [], line_claims: []
        )
        next unless decision.fetch(:eligible)

        {
          "line_id" => row.fetch("line_id"),
          "abstraction_similarity" => Float(row.fetch("abstraction_similarity")),
          "surface_similarity" => Float(row.fetch("surface_similarity")),
          "domain_primary" => Bv2SelectorComparison::DOMAIN_MAP.fetch(line.fetch("theme"), "other")
        }
      end
    end

    def verify_uniform_reproduction(selections_path)
      source = CSV.read(
        File.join(@configuration.root_dir, "data", "evaluations", "b_v2_band_sensitivity_v1", "b_v2_band_sensitivity_selections_v1.csv"),
        headers: true, encoding: "UTF-8"
      )
      replay = CSV.read(selections_path, headers: true, encoding: "UTF-8")
      @criteria.fetch("bands").to_h do |band_name, band|
        setting_id = format(
          "A%04d_S%04d_N%03d",
          (Float(band.fetch("a_min")) * 1000).round,
          (Float(band.fetch("s_max")) * 1000).round,
          Integer(band.fetch("top_n"))
        )
        expected = source.select { |row| row.fetch("setting_id") == setting_id }
                         .to_h { |row| [[row.fetch("entry_id"), row.fetch("repetition")], row] }
        actual = replay.select { |row| row.fetch("band") == band_name && row.fetch("selector") == "uniform" }
                       .to_h { |row| [[row.fetch("entry_id"), row.fetch("repetition")], row] }
        mismatches = expected.filter_map do |slot, expected_row|
          actual_row = actual.fetch(slot)
          fields = {
            line_id: [expected_row.fetch("selected_line_id"), actual_row.fetch("selected_line_id")],
            status: [expected_row.fetch("status"), actual_row.fetch("status")],
            eligible_count: [Integer(expected_row.fetch("eligible_count")), Integer(actual_row.fetch("eligible_count"))]
          }
          differences = fields.select { |_field, values| values.fetch(0) != values.fetch(1) }
          differences.empty? ? nil : { slot: slot, differences: differences }
        end
        [band_name, { exact: mismatches.empty?, mismatch_count: mismatches.length, examples: mismatches.first(10) }]
      end
    end

    def write_missing_review(path, selected_pairs)
      existing_ids = CSV.read(source_path("pair_judgments"), headers: true, encoding: "UTF-8")
                        .map { |row| row.fetch("pair_id") }.to_h { |pair_id| [pair_id, true] }
      missing_ids = selected_pairs.keys.reject { |pair_id| existing_ids.key?(pair_id) }.sort
      headers = %w[
        pair_id entry_id line_id entry_text line_text line_theme line_meaning
        selection_occurrences selector_count band_count acceptable distance relation_type
        confidence low_confidence judge provisional reason
      ]
      CSV.open(path, "w:UTF-8", write_headers: true, headers: headers) do |csv|
        missing_ids.each do |pair_id|
          entry_id, line_id = pair_id.split("/")
          pair = selected_pairs.fetch(pair_id)
          line = @lines.fetch(line_id)
          csv << [
            pair_id, entry_id, line_id, @entries.fetch(entry_id).fetch("body"), line.fetch("text"),
            line.fetch("theme"), line.fetch("meaning"), pair.fetch(:occurrences),
            pair.fetch(:selectors).length, pair.fetch(:bands).length,
            nil, nil, nil, nil, nil, nil, nil, nil
          ]
        end
      end
      {
        selected_unique_pair_count: selected_pairs.length,
        already_labeled_pair_count: selected_pairs.length - missing_ids.length,
        new_codex_provisional_review_required_count: missing_ids.length,
        quality_labels_used_during_selection: false
      }
    end

    def selection_headers
      %w[
        band a_min s_max top_n selector entry_id repetition eligible_count status selected_line_id seed
        reproducible selected_weight minimum_weight maximum_weight maximum_weight_ratio
        selected_abstraction_similarity selected_surface_similarity selected_domain_primary
      ]
    end

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
