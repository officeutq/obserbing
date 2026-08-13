# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "yaml"

module AiLineSelection
  class Bv2BandSensitivity
    VERSION = "b-v2-band-sensitivity-mechanical-v1"
    A_MINS = (350..600).step(25).map { |value| value / 1000.0 }.freeze
    S_MAXES = (350..700).step(25).map { |value| value / 1000.0 }.freeze
    TOP_NS = [5, 10, 20, 40, 96].freeze
    CURRENT = { a_min: 0.45, s_max: 0.55, top_n: 20 }.freeze
    EXPECTED_PAIR_COUNT = 108 * 96

    def initialize(configuration:, issue_46_results_dir:, completion_results_dir:)
      @configuration = configuration
      @issue_46_results_dir = File.expand_path(issue_46_results_dir)
      @completion_results_dir = File.expand_path(completion_results_dir)
      @data = DataLoader.new(configuration)
      @entries = @data.entries.to_h { |entry| [entry.fetch("id"), entry] }
      @lines = @data.lines.select { |line| line.fetch("status") == "approved" }
                    .to_h { |line| [line.fetch("id"), line] }
      @guard = Bv2PolicyGuard.new(configuration: configuration)
    end

    def prepare(output_dir:)
      source_rows = load_pair_rows
      live_rows = read_jsonl(issue_46_path("provider_outputs.jsonl"))
      validate_sources!(source_rows, live_rows)

      output_dir = File.expand_path(output_dir)
      FileUtils.mkdir_p(output_dir)
      pair_path = File.join(output_dir, "b_v2_band_sensitivity_pair_similarities_v1.csv")
      FileUtils.cp(completion_path("pair_similarities.csv"), pair_path)

      indexed = source_rows.group_by { |row| [row.fetch("entry_id"), Integer(row.fetch("repetition"))] }
      selection_path = File.join(output_dir, "b_v2_band_sensitivity_selections_v1.csv")
      mechanical_path = File.join(output_dir, "b_v2_band_sensitivity_mechanical_v1.jsonl")
      summaries = []
      selected_pair_occurrences = Hash.new(0)
      selected_pair_configs = Hash.new { |hash, key| hash[key] = {} }

      CSV.open(selection_path, "w:UTF-8", write_headers: true, headers: selection_headers) do |csv|
        settings.each do |setting|
          summary = sweep_setting(setting, indexed, csv, selected_pair_occurrences, selected_pair_configs)
          summaries << summary
        end
      end
      write_jsonl(mechanical_path, summaries)

      review_path = File.join(output_dir, "b_v2_band_sensitivity_pair_judgments_v1.csv")
      label_summary = write_review_pairs(review_path, selected_pair_occurrences, selected_pair_configs)
      reproduction = current_reproduction(summaries, selection_path, live_rows)
      raise DataError.new("Current B-v2 setting was not exactly reproduced", details: reproduction) unless reproduction.fetch(:exact)

      manifest = {
        version: VERSION,
        issue: 59,
        purpose: "post_hoc_follow_up_diagnostic",
        changes_existing_gate_a_or_epic_40_decision: false,
        network_call_performed: false,
        external_api_calls: 0,
        profile_version: Bv2IntegratedComparison::PROFILE_VERSION,
        embedding_version: Bv2IntegratedComparison::EMBEDDING_VERSION,
        policy_version: @guard.version,
        selector_version: Bv2Selector::VERSION,
        selector_strategy: "uniform",
        line_pool_count: @lines.length,
        outcome_slots: indexed.length,
        pair_similarity_count: source_rows.length,
        grid: {
          a_min_values: A_MINS,
          s_max_values: S_MAXES,
          top_n_values: TOP_NS,
          setting_count: settings.length
        },
        current_setting: CURRENT,
        current_setting_reproduction: reproduction,
        quality_labels: label_summary,
        separation_of_evidence: {
          similarity: "provider_cosine_from_saved_pair_artifact",
          quality: "reflective-distance-v1 judgment artifact",
          similarity_used_as_quality_label: false
        },
        source_hashes: source_hashes,
        artifact_hashes: {
          pair_similarities_sha256: Digest::SHA256.file(pair_path).hexdigest,
          selections_sha256: Digest::SHA256.file(selection_path).hexdigest,
          mechanical_sha256: Digest::SHA256.file(mechanical_path).hexdigest,
          pair_judgments_sha256: Digest::SHA256.file(review_path).hexdigest
        }
      }
      manifest_path = File.join(output_dir, "b_v2_band_sensitivity_manifest_v1.json")
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w:UTF-8")
      manifest.merge(output_dir: output_dir, manifest_path: manifest_path)
    rescue Errno::ENOENT, CSV::MalformedCSVError, JSON::ParserError, Psych::Exception, KeyError => e
      raise DataError.new(
        "B-v2 band sensitivity source is invalid",
        details: { error: e.class.name, message: e.message, source_line: e.backtrace&.first }
      )
    end

    def apply_codex_review(output_dir:, review_path:)
      output_dir = File.expand_path(output_dir)
      judgments_path = File.join(output_dir, "b_v2_band_sensitivity_pair_judgments_v1.csv")
      rows = CSV.read(judgments_path, headers: true, encoding: "UTF-8")
      review = YAML.safe_load_file(File.expand_path(review_path), permitted_classes: [], aliases: false)
      validate_review_header!(review)
      missing = rows.select { |row| row.fetch("acceptable").to_s.empty? }
      missing_ids = missing.map { |row| row.fetch("pair_id") }.to_h { |pair_id| [pair_id, true] }
      decisions = expand_review_decisions(review, missing_ids)

      CSV.open(judgments_path, "w:UTF-8", write_headers: true, headers: rows.headers) do |csv|
        rows.each do |row|
          decision = decisions[row.fetch("pair_id")]
          if decision
            row = CSV::Row.new(rows.headers, rows.headers.map { |header| decision.fetch(header, row[header]) })
          end
          csv << row
        end
      end
      remaining = CSV.read(judgments_path, headers: true, encoding: "UTF-8")
                     .count { |row| row.fetch("acceptable").to_s.empty? }
      raise DataError.new("Codex provisional review did not cover every selected pair") unless remaining.zero?

      manifest_path = File.join(output_dir, "b_v2_band_sensitivity_manifest_v1.json")
      manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      judgment_hash = Digest::SHA256.file(judgments_path).hexdigest
      manifest.fetch("artifact_hashes")["pair_judgments_sha256"] = judgment_hash
      manifest.fetch("quality_labels")["new_codex_provisional_judgment_count"] = decisions.length
      manifest.fetch("quality_labels")["new_codex_provisional_low_confidence_count"] =
        decisions.values.count { |value| value.fetch("confidence") == "low" }
      manifest.fetch("quality_labels")["unlabeled_pair_count"] = 0
      manifest.fetch("source_hashes")["codex_review_spec_sha256"] = Digest::SHA256.file(File.expand_path(review_path)).hexdigest
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w:UTF-8")

      {
        version: review.fetch("version"),
        network_call_performed: false,
        external_api_calls: 0,
        codex_provisional_judgment_count: decisions.length,
        low_confidence_count: decisions.values.count { |value| value.fetch("confidence") == "low" },
        judgments_path: judgments_path,
        judgments_sha256: judgment_hash,
        review_spec_sha256: Digest::SHA256.file(File.expand_path(review_path)).hexdigest
      }
    end

    def evaluate(output_dir:)
      output_dir = File.expand_path(output_dir)
      selections_path = File.join(output_dir, "b_v2_band_sensitivity_selections_v1.csv")
      judgments_path = File.join(output_dir, "b_v2_band_sensitivity_pair_judgments_v1.csv")
      mechanical_path = File.join(output_dir, "b_v2_band_sensitivity_mechanical_v1.jsonl")
      labels = load_sweep_labels(judgments_path)
      selections = CSV.read(selections_path, headers: true, encoding: "UTF-8")
      mechanical = read_jsonl(mechanical_path).to_h { |row| [row.fetch("setting_id"), row] }
      pair_rows = load_pair_rows.group_by { |row| [row.fetch("entry_id"), Integer(row.fetch("repetition"))] }

      quality = selections.group_by { |row| row.fetch("setting_id") }.map do |setting_id, rows|
        evaluate_setting(rows, labels, mechanical.fetch(setting_id), pair_rows)
      end.sort_by { |row| row.fetch(:setting_id) }
      quality_path = File.join(output_dir, "b_v2_band_sensitivity_quality_v1.jsonl")
      write_jsonl(quality_path, quality)

      heatmaps = build_heatmaps(quality)
      heatmaps_path = File.join(output_dir, "b_v2_band_sensitivity_heatmaps_v1.json")
      File.write(heatmaps_path, JSON.pretty_generate(heatmaps), mode: "w:UTF-8")
      analysis = build_analysis(quality).merge(
        version: "b-v2-band-sensitivity-analysis-v1",
        issue: 59,
        post_hoc_follow_up: true,
        changes_existing_gate_a_or_epic_40_decision: false,
        network_call_performed: false,
        external_api_calls_after_entry_embedding_completion: 0,
        provisional_quality_judgments: true,
        human_quality_judgments_preserved_where_available: true,
        source_hashes: {
          selections_sha256: Digest::SHA256.file(selections_path).hexdigest,
          judgments_sha256: Digest::SHA256.file(judgments_path).hexdigest,
          pair_similarities_sha256: Digest::SHA256.file(completion_path("pair_similarities.csv")).hexdigest
        }
      )
      analysis_path = File.join(output_dir, "b_v2_band_sensitivity_analysis_v1.json")
      File.write(analysis_path, JSON.pretty_generate(analysis), mode: "w:UTF-8")
      manifest_path = File.join(output_dir, "b_v2_band_sensitivity_manifest_v1.json")
      manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
      manifest.fetch("artifact_hashes").merge!(
        "quality_sha256" => Digest::SHA256.file(quality_path).hexdigest,
        "heatmaps_sha256" => Digest::SHA256.file(heatmaps_path).hexdigest,
        "analysis_sha256" => Digest::SHA256.file(analysis_path).hexdigest
      )
      manifest["offline_evaluation"] = {
        "completed" => true, "setting_count" => quality.length,
        "external_api_calls" => 0, "selected_pair_label_coverage_rate" => 1.0
      }
      File.write(manifest_path, JSON.pretty_generate(manifest), mode: "w:UTF-8")
      {
        completed: true, setting_count: quality.length,
        quality_path: quality_path, heatmaps_path: heatmaps_path, analysis_path: analysis_path,
        current_setting: analysis.fetch(:current_setting), best_point: analysis.fetch(:best_point),
        largest_near_best_region: analysis.fetch(:largest_near_best_region),
        network_call_performed: false, external_api_calls: 0
      }
    end

    private

    def load_sweep_labels(path)
      rows = CSV.read(path, headers: true, encoding: "UTF-8")
      missing = rows.select { |row| row.fetch("acceptable").to_s.empty? }
      raise DataError.new("Sweep quality labels are incomplete", details: { missing: missing.length }) unless missing.empty?

      rows.to_h do |row|
        acceptable = boolean(row.fetch("acceptable"))
        distance = row.fetch("distance")
        relation = row.fetch("relation_type")
        valid = acceptable ?
          distance == "just_right" && %w[same_domain analogical_transfer].include?(relation) :
          %w[too_close too_far not_obserbing].include?(distance) && %w[direct_restatement weak_connection unrelated].include?(relation)
        raise DataError.new("Sweep judgment violates reflective-distance-v1", details: { pair_id: row.fetch("pair_id") }) unless valid

        [row.fetch("pair_id"), row.to_h.merge("acceptable" => acceptable)]
      end
    end

    def evaluate_setting(rows, labels, mechanical, pair_rows)
      outcomes = rows.map do |row|
        line_id = blank_to_nil(row.fetch("selected_line_id"))
        if line_id
          labels.fetch("#{row.fetch('entry_id')}/#{line_id}").merge(
            "entry_id" => row.fetch("entry_id"), "repetition" => Integer(row.fetch("repetition")),
            "selected_line_id" => line_id
          )
        else
          {
            "entry_id" => row.fetch("entry_id"), "repetition" => Integer(row.fetch("repetition")),
            "selected_line_id" => nil, "acceptable" => false,
            "distance" => "semantic_silence", "relation_type" => "semantic_silence",
            "confidence" => "not_applicable", "judge" => "selector_outcome", "provisional" => false
          }
        end
      end
      acceptable = outcomes.count { |row| row.fetch("acceptable") }
      all_three = outcomes.group_by { |row| row.fetch("entry_id") }.count do |_entry_id, entry_rows|
        entry_rows.length == 3 && entry_rows.all? { |row| row.fetch("acceptable") }
      end
      low = outcomes.select { |row| row.fetch("confidence") == "low" }
      selector = selector_opportunity(rows, labels, pair_rows)
      {
        setting_id: mechanical.fetch("setting_id"),
        a_min: mechanical.fetch("a_min"), s_max: mechanical.fetch("s_max"), top_n: mechanical.fetch("top_n"),
        outcome_count: outcomes.length,
        eligible_count: mechanical.fetch("eligible_count"),
        semantic_silence_count: mechanical.fetch("semantic_silence_count"),
        semantic_silence_rate: mechanical.fetch("semantic_silence_rate"),
        selected_count: mechanical.fetch("selected_count"),
        acceptable_count: acceptable,
        acceptable_rate: ratio(acceptable, outcomes.length),
        all_three_repetitions_acceptable_entry_count: all_three,
        all_three_repetitions_acceptable_entry_rate: ratio(all_three, @entries.length),
        distance_counts: outcomes.map { |row| row.fetch("distance") }.tally.sort.to_h,
        relation_type_counts: outcomes.map { |row| row.fetch("relation_type") }.tally.sort.to_h,
        analogical_transfer_count: outcomes.count { |row| row.fetch("relation_type") == "analogical_transfer" },
        low_confidence_occurrence_count: low.length,
        low_confidence_pair_count: low.map { |row| "#{row.fetch('entry_id')}/#{row.fetch('selected_line_id')}" }.uniq.length,
        selector_opportunity_lower_bound: selector
      }
    end

    def selector_opportunity(rows, labels, pair_rows)
      eligible_occurrences = 0
      labeled_eligible_occurrences = 0
      slots_with_known_acceptable = 0
      missed = 0
      rows.each do |row|
        setting = {
          a_min: Float(row.fetch("a_min")), s_max: Float(row.fetch("s_max")), top_n: Integer(row.fetch("top_n"))
        }
        candidates = eligible_rows(
          pair_rows.fetch([row.fetch("entry_id"), Integer(row.fetch("repetition"))]),
          row.fetch("entry_id"), setting
        )
        eligible_occurrences += candidates.length
        known = candidates.filter_map { |candidate| labels["#{row.fetch('entry_id')}/#{candidate.fetch('line_id')}"] }
        labeled_eligible_occurrences += known.length
        has_acceptable = known.any? { |label| label.fetch("acceptable") }
        next unless has_acceptable

        slots_with_known_acceptable += 1
        selected_id = blank_to_nil(row.fetch("selected_line_id"))
        selected_label = selected_id && labels.fetch("#{row.fetch('entry_id')}/#{selected_id}")
        missed += 1 unless selected_label && selected_label.fetch("acceptable")
      end
      {
        eligible_candidate_occurrences: eligible_occurrences,
        labeled_eligible_candidate_occurrences: labeled_eligible_occurrences,
        labeled_eligible_coverage_rate: ratio(labeled_eligible_occurrences, eligible_occurrences),
        slots_with_known_acceptable_candidate: slots_with_known_acceptable,
        uniform_missed_known_acceptable_count: missed,
        uniform_missed_known_acceptable_rate: ratio(missed, slots_with_known_acceptable),
        interpretation: "lower_bound_because_unselected_unlabeled_pairs_are_not_assumed_bad"
      }
    end

    def eligible_rows(rows, entry_id, setting)
      rows.sort_by { |row| [-Float(row.fetch("abstraction_similarity")), row.fetch("line_id")] }
          .first(setting.fetch(:top_n)).filter_map do |row|
        next if Float(row.fetch("abstraction_similarity")) < setting.fetch(:a_min)
        next if Float(row.fetch("surface_similarity")) > setting.fetch(:s_max)
        line = @lines.fetch(row.fetch("line_id"))
        decision = @guard.evaluate(
          entry: @entries.fetch(entry_id), line: line,
          profile_version: Bv2IntegratedComparison::PROFILE_VERSION,
          embedding_version: Bv2IntegratedComparison::EMBEDDING_VERSION,
          history: [], line_claims: []
        )
        decision.fetch(:eligible) ? row : nil
      end
    end

    def build_heatmaps(quality)
      {
        version: "b-v2-band-sensitivity-heatmaps-v1",
        row_axis: { name: "a_min", values: A_MINS },
        column_axis: { name: "s_max", values: S_MAXES },
        panels: TOP_NS.to_h do |top_n|
          rows = quality.select { |row| row.fetch(:top_n) == top_n }
          [top_n.to_s, {
            acceptable_rate: matrix(rows, :acceptable_rate),
            all_three_repetitions_acceptable_entry_rate: matrix(rows, :all_three_repetitions_acceptable_entry_rate),
            semantic_silence_rate: matrix(rows, :semantic_silence_rate),
            too_close_rate: count_matrix(rows, "too_close"),
            too_far_rate: count_matrix(rows, "too_far")
          }]
        end
      }
    end

    def matrix(rows, field)
      A_MINS.map do |a_min|
        S_MAXES.map do |s_max|
          rows.find { |row| row.fetch(:a_min) == a_min && row.fetch(:s_max) == s_max }.fetch(field)
        end
      end
    end

    def count_matrix(rows, label)
      A_MINS.map do |a_min|
        S_MAXES.map do |s_max|
          row = rows.find { |candidate| candidate.fetch(:a_min) == a_min && candidate.fetch(:s_max) == s_max }
          ratio(row.fetch(:distance_counts).fetch(label, 0), row.fetch(:outcome_count))
        end
      end
    end

    def build_analysis(quality)
      sorted = quality.sort_by do |row|
        [-row.fetch(:acceptable_rate), -row.fetch(:all_three_repetitions_acceptable_entry_rate), row.fetch(:semantic_silence_rate), row.fetch(:setting_id)]
      end
      best = sorted.first
      current = quality.find do |row|
        row.fetch(:a_min) == CURRENT.fetch(:a_min) && row.fetch(:s_max) == CURRENT.fetch(:s_max) && row.fetch(:top_n) == CURRENT.fetch(:top_n)
      end
      threshold = [best.fetch(:acceptable_rate) - 0.02, 0.0].max.round(6)
      regions = TOP_NS.flat_map { |top_n| connected_regions(quality, top_n, threshold) }
      largest = regions.max_by { |region| [region.fetch(:cell_count), region.fetch(:acceptable_rate_mean)] }
      {
        setting_count: quality.length,
        current_setting: summarize_setting(current).merge(
          rank_by_acceptable_then_all_three: sorted.index(current) + 1,
          acceptable_percentile: ratio(quality.count { |row| row.fetch(:acceptable_rate) <= current.fetch(:acceptable_rate) }, quality.length)
        ),
        best_point: summarize_setting(best),
        near_best_definition: {
          acceptable_rate_within_points_of_global_maximum: 2.0,
          four_neighbor_connectivity_within_each_top_n_panel: true,
          threshold_rate: threshold
        },
        near_best_region_count: regions.length,
        largest_near_best_region: largest,
        top_n_influence: TOP_NS.map { |top_n| top_n_summary(quality, top_n) },
        tradeoff: tradeoff_summary(quality),
        quality_evidence: {
          selected_pair_label_coverage_rate: 1.0,
          similarity_and_quality_stored_separately: true,
          codex_labels_are_provisional: true
        }
      }
    end

    def connected_regions(quality, top_n, threshold)
      candidates = quality.select { |row| row.fetch(:top_n) == top_n && row.fetch(:acceptable_rate) >= threshold }
      lookup = candidates.to_h { |row| [[row.fetch(:a_min), row.fetch(:s_max)], row] }
      regions = []
      until lookup.empty?
        first_key = lookup.keys.first
        queue = [first_key]
        cells = []
        while (key = queue.shift)
          row = lookup.delete(key)
          next unless row
          cells << row
          a_min, s_max = key
          [[a_min - 0.025, s_max], [a_min + 0.025, s_max], [a_min, s_max - 0.025], [a_min, s_max + 0.025]].each do |neighbor|
            rounded = neighbor.map { |value| value.round(3) }
            queue << rounded if lookup.key?(rounded)
          end
        end
        rates = cells.map { |row| row.fetch(:acceptable_rate) }
        regions << {
          top_n: top_n, cell_count: cells.length,
          a_min_range: cells.map { |row| row.fetch(:a_min) }.minmax,
          s_max_range: cells.map { |row| row.fetch(:s_max) }.minmax,
          acceptable_rate_minimum: rates.min,
          acceptable_rate_mean: (rates.sum / rates.length).round(6),
          acceptable_rate_maximum: rates.max,
          settings: cells.map { |row| row.fetch(:setting_id) }.sort
        }
      end
      regions
    end

    def top_n_summary(quality, top_n)
      rows = quality.select { |row| row.fetch(:top_n) == top_n }
      rates = rows.map { |row| row.fetch(:acceptable_rate) }
      best = rows.max_by { |row| [row.fetch(:acceptable_rate), row.fetch(:all_three_repetitions_acceptable_entry_rate), -row.fetch(:semantic_silence_rate)] }
      {
        top_n: top_n,
        acceptable_rate_minimum: rates.min,
        acceptable_rate_mean: (rates.sum / rates.length).round(6),
        acceptable_rate_maximum: rates.max,
        semantic_silence_rate_mean: (rows.sum { |row| row.fetch(:semantic_silence_rate) } / rows.length).round(6),
        best_setting: summarize_setting(best)
      }
    end

    def tradeoff_summary(quality)
      pairs = quality.map do |row|
        [ratio(row.fetch(:distance_counts).fetch("too_close", 0), row.fetch(:outcome_count)),
         ratio(row.fetch(:distance_counts).fetch("too_far", 0), row.fetch(:outcome_count))]
      end
      a_steps = adjacent_changes(quality, :a_min, "too_far")
      s_steps = adjacent_changes(quality, :s_max, "too_close")
      {
        too_close_too_far_pearson_correlation: pearson(pairs),
        raising_a_min_effect_on_too_far: a_steps,
        relaxing_s_max_effect_on_too_close: s_steps
      }
    end

    def adjacent_changes(quality, axis, distance_label)
      other_axes = axis == :a_min ? %i[s_max top_n] : %i[a_min top_n]
      changes = quality.group_by { |row| other_axes.map { |name| row.fetch(name) } }.flat_map do |_key, rows|
        rows.sort_by { |row| row.fetch(axis) }.each_cons(2).map do |left, right|
          right.fetch(:distance_counts).fetch(distance_label, 0) - left.fetch(:distance_counts).fetch(distance_label, 0)
        end
      end
      {
        comparison_count: changes.length,
        increased_count: changes.count(&:positive?),
        unchanged_count: changes.count(&:zero?),
        decreased_count: changes.count(&:negative?),
        mean_occurrence_change: (changes.sum.to_f / changes.length).round(6)
      }
    end

    def pearson(pairs)
      xs = pairs.map(&:first)
      ys = pairs.map(&:last)
      x_mean = xs.sum / xs.length
      y_mean = ys.sum / ys.length
      numerator = pairs.sum { |x, y| (x - x_mean) * (y - y_mean) }
      denominator = Math.sqrt(xs.sum { |x| (x - x_mean)**2 } * ys.sum { |y| (y - y_mean)**2 })
      denominator.zero? ? 0.0 : (numerator / denominator).round(6)
    end

    def summarize_setting(row)
      row.slice(
        :setting_id, :a_min, :s_max, :top_n, :acceptable_count, :acceptable_rate,
        :all_three_repetitions_acceptable_entry_count, :all_three_repetitions_acceptable_entry_rate,
        :semantic_silence_count, :semantic_silence_rate, :eligible_count,
        :distance_counts, :relation_type_counts, :analogical_transfer_count,
        :low_confidence_occurrence_count, :low_confidence_pair_count,
        :selector_opportunity_lower_bound
      )
    end

    def boolean(value)
      case value
      when true, "true" then true
      when false, "false" then false
      else raise DataError.new("Invalid boolean in sweep judgment", details: { value: value })
      end
    end

    def validate_review_header!(review)
      unless review.fetch("rubric") == "reflective-distance-v1" && review.fetch("judge") == "codex_provisional" && review.fetch("provisional")
        raise DataError.new("Band sensitivity Codex review header is invalid")
      end
      raise DataError.new("Codex review must not use an external API") unless Integer(review.fetch("external_api_calls")).zero?
    end

    def expand_review_decisions(review, missing_ids)
      decisions = {}
      review.fetch("decisions").each do |entry_id, entry_review|
        categories = %w[acceptable too_close unrelated]
        categorized = categories.flat_map { |category| Array(entry_review.fetch(category)) }
        if categorized.uniq.length != categorized.length
          raise DataError.new("Codex review contains duplicate categories", details: { entry_id: entry_id })
        end
        low = Array(entry_review.fetch("low_confidence"))
        pair_line_ids = missing_ids.keys.filter_map { |pair_id| pair_id.split("/").last if pair_id.start_with?("#{entry_id}/") }
        unknown = (categorized + low).uniq - pair_line_ids
        unless unknown.empty?
          raise DataError.new("Codex review references a pair outside the missing review scope", details: { entry_id: entry_id, line_ids: unknown })
        end
        pair_line_ids.each do |line_id|
          category = categories.find { |name| Array(entry_review.fetch(name)).include?(line_id) } || "weak_connection"
          pair_id = "#{entry_id}/#{line_id}"
          decisions[pair_id] = codex_decision(
            entry_id, line_id, category, low.include?(line_id)
          )
        end
      end
      unless decisions.keys.sort == missing_ids.keys.sort
        absent = missing_ids.keys - decisions.keys
        raise DataError.new("Codex review is missing Entry groups", details: { pair_ids: absent.first(20) })
      end
      decisions
    end

    def codex_decision(entry_id, line_id, category, low_confidence)
      line = @lines.fetch(line_id)
      case category
      when "acceptable"
        same_domain = Array(@entries.fetch(entry_id).dig("expected", "themes")).include?(line.fetch("theme"))
        acceptable = true
        distance = "just_right"
        relation = same_domain ? "same_domain" : "analogical_transfer"
        reason = "Codex provisional: the Line meaning '#{line.fetch('meaning')}' provides a usable reflective bridge without merely restating the Entry."
      when "too_close"
        acceptable = false
        distance = "too_close"
        relation = "direct_restatement"
        reason = "Codex provisional: the Line meaning '#{line.fetch('meaning')}' follows the Entry structure too directly to create reflective distance."
      when "unrelated"
        acceptable = false
        distance = "not_obserbing"
        relation = "unrelated"
        reason = "Codex provisional: the Line meaning '#{line.fetch('meaning')}' does not provide a meaningful bridge to the Entry."
      when "weak_connection"
        acceptable = false
        distance = "too_far"
        relation = "weak_connection"
        reason = "Codex provisional: the Line meaning '#{line.fetch('meaning')}' has a conceivable bridge, but it is too indirect to support the Entry reliably."
      else
        raise DataError.new("Unknown Codex review category", details: { category: category })
      end
      {
        "label_source" => "b_v2_band_sensitivity_codex_review_v1",
        "judge" => "codex_provisional", "provisional" => true,
        "acceptable" => acceptable, "distance" => distance, "relation_type" => relation,
        "confidence" => low_confidence ? "low" : (category == "unrelated" || category == "too_close" ? "high" : "medium"),
        "low_confidence" => low_confidence,
        "user_fact_assertion" => false, "explicit_contradiction" => false,
        "advice_or_diagnosis" => false, "clearly_unrelated" => category == "unrelated",
        "reason" => reason
      }
    end

    def settings
      @settings ||= A_MINS.product(S_MAXES, TOP_NS).map do |a_min, s_max, top_n|
        { id: setting_id(a_min, s_max, top_n), a_min: a_min, s_max: s_max, top_n: top_n }
      end
    end

    def setting_id(a_min, s_max, top_n)
      format("A%04d_S%04d_N%03d", (a_min * 1000).round, (s_max * 1000).round, top_n)
    end

    def sweep_setting(setting, indexed, csv, pair_occurrences, pair_configs)
      counts = []
      silences = 0
      selected = []
      indexed.sort.each do |(entry_id, repetition), rows|
        result = select(rows, entry_id, repetition, setting)
        counts << result.fetch(:eligible_count)
        silences += 1 if result.fetch(:selected_line_id).nil?
        line_id = result.fetch(:selected_line_id)
        if line_id
          pair_id = "#{entry_id}/#{line_id}"
          pair_occurrences[pair_id] += 1
          pair_configs[pair_id][setting.fetch(:id)] = true
          selected << line_id
        end
        csv << [
          setting.fetch(:id), setting.fetch(:a_min), setting.fetch(:s_max), setting.fetch(:top_n),
          entry_id, repetition, result.fetch(:eligible_count), line_id, result.fetch(:status),
          result.fetch(:seed), result.fetch(:abstraction_similarity), result.fetch(:surface_similarity)
        ]
      end
      {
        setting_id: setting.fetch(:id),
        a_min: setting.fetch(:a_min), s_max: setting.fetch(:s_max), top_n: setting.fetch(:top_n),
        outcome_count: indexed.length,
        eligible_count: {
          p50: percentile(counts, 0.50), p95: percentile(counts, 0.95),
          minimum: counts.min, maximum: counts.max,
          zero_count: silences, zero_rate: ratio(silences, counts.length)
        },
        semantic_silence_count: silences,
        semantic_silence_rate: ratio(silences, counts.length),
        selected_count: selected.length,
        selected_unique_line_count: selected.uniq.length
      }
    end

    def select(rows, entry_id, repetition, setting)
      ranked = rows.sort_by { |row| [-Float(row.fetch("abstraction_similarity")), row.fetch("line_id")] }
                   .first(setting.fetch(:top_n))
      eligible = ranked.filter_map do |row|
        next if Float(row.fetch("abstraction_similarity")) < setting.fetch(:a_min)
        next if Float(row.fetch("surface_similarity")) > setting.fetch(:s_max)

        line = @lines.fetch(row.fetch("line_id"))
        decision = @guard.evaluate(
          entry: @entries.fetch(entry_id), line: line,
          profile_version: Bv2IntegratedComparison::PROFILE_VERSION,
          embedding_version: Bv2IntegratedComparison::EMBEDDING_VERSION,
          history: [], line_claims: []
        )
        next unless decision.fetch(:eligible)

        row.merge("line" => line)
      end
      seed = Bv2Selector.seed(
        base_seed: @configuration.random_seed, entry_id: entry_id, repetition: repetition
      )
      choice = Bv2Selector.new(strategy: "uniform").select(candidates: eligible, seed: seed)
      selected = eligible.find { |row| row.fetch("line_id") == choice.fetch(:line_id) }
      {
        status: choice.fetch(:status), selected_line_id: choice.fetch(:line_id),
        eligible_count: eligible.length, seed: choice.fetch(:seed),
        abstraction_similarity: selected && Float(selected.fetch("abstraction_similarity")),
        surface_similarity: selected && Float(selected.fetch("surface_similarity"))
      }
    end

    def current_reproduction(summaries, selection_path, live_rows)
      id = setting_id(CURRENT.fetch(:a_min), CURRENT.fetch(:s_max), CURRENT.fetch(:top_n))
      selected = CSV.read(selection_path, headers: true, encoding: "UTF-8")
                    .select { |row| row.fetch("setting_id") == id }
                    .to_h { |row| [[row.fetch("entry_id"), Integer(row.fetch("repetition"))], row] }
      mismatches = live_rows.filter_map do |live|
        replay = selected.fetch([live.fetch("entry_id"), Integer(live.fetch("repetition"))])
        fields = {
          status: [live.fetch("status"), replay.fetch("status")],
          line_id: [live["selected_line_id"], blank_to_nil(replay["selected_line_id"])],
          eligible_count: [Integer(live.fetch("eligible_count")), Integer(replay.fetch("eligible_count"))]
        }
        differences = fields.select { |_key, values| values.fetch(0) != values.fetch(1) }
        differences.empty? ? nil : { entry_id: live.fetch("entry_id"), repetition: live.fetch("repetition"), differences: differences }
      end
      summary = summaries.find { |row| row.fetch(:setting_id) == id }
      {
        exact: mismatches.empty?, mismatch_count: mismatches.length,
        mismatch_examples: mismatches.first(10),
        selected_count: summary.fetch(:selected_count),
        semantic_silence_count: summary.fetch(:semantic_silence_count)
      }
    end

    def write_review_pairs(path, occurrences, configs)
      labels = existing_labels
      missing = 0
      low = 0
      headers = %w[
        pair_id entry_id line_id entry_text line_text selection_occurrences configuration_count
        label_source judge provisional acceptable distance relation_type confidence low_confidence
        user_fact_assertion explicit_contradiction advice_or_diagnosis clearly_unrelated reason
      ]
      CSV.open(path, "w:UTF-8", write_headers: true, headers: headers) do |csv|
        occurrences.keys.sort.each do |pair_id|
          entry_id, line_id = pair_id.split("/")
          label = labels[pair_id]
          missing += 1 unless label
          low += 1 if label && label.fetch("confidence", nil) == "low"
          csv << [
            pair_id, entry_id, line_id, @entries.fetch(entry_id).fetch("body"), @lines.fetch(line_id).fetch("text"),
            occurrences.fetch(pair_id), configs.fetch(pair_id).length,
            label && label.fetch("label_source"), label && label.fetch("judge"), label && label.fetch("provisional"),
            label && label.fetch("acceptable"), label && label.fetch("distance"), label && label.fetch("relation_type"),
            label && label.fetch("confidence"), label && (label.fetch("confidence") == "low"),
            label && label.fetch("user_fact_assertion"), label && label.fetch("explicit_contradiction"),
            label && label.fetch("advice_or_diagnosis"), label && label.fetch("clearly_unrelated"),
            label && label.fetch("reason")
          ]
        end
      end
      {
        selected_unique_pair_count: occurrences.length,
        already_labeled_pair_count: occurrences.length - missing,
        new_codex_provisional_judgment_required_count: missing,
        existing_low_confidence_pair_count: low,
        all_judgments_are_separate_from_similarity: true
      }
    end

    def existing_labels
      labels = load_codex_labels(evaluation_path("reflective_distance_codex_judgments_v1.csv"), "codex_reassessment")
      load_codex_labels(evaluation_path("b_v2_integrated_codex_judgments_v1.csv"), "codex_integrated_v1").each do |pair_id, label|
        labels[pair_id] = label
      end
      human = YAML.safe_load_file(evaluation_path("reflective_distance_human_review_v1.yml"), permitted_classes: [], aliases: false)
      human.fetch("reviews").each do |review|
        labels[review.fetch("pair_id")] = stringify(review.fetch("final_labels")).merge(
          "label_source" => "reflective_distance_human_review_v1",
          "judge" => "human_review", "provisional" => false,
          "confidence" => "human_confirmed",
          "reason" => "Product-owner decision normalized to reflective-distance-v1."
        )
      end
      labels
    end

    def load_codex_labels(path, judge)
      CSV.read(path, headers: true, encoding: "UTF-8").to_h do |row|
        value = row.to_h.merge(
          "label_source" => File.basename(path, ".csv"),
          "judge" => judge, "provisional" => true
        )
        [row.fetch("pair_id"), value]
      end
    end

    def stringify(hash)
      hash.to_h.transform_keys(&:to_s)
    end

    def validate_sources!(rows, live_rows)
      unless rows.length == EXPECTED_PAIR_COUNT && rows.map { |row| [row.fetch("entry_id"), row.fetch("repetition"), row.fetch("line_id")] }.uniq.length == EXPECTED_PAIR_COUNT
        raise DataError.new("Pair similarity artifact must contain 10,368 unique pairs")
      end
      unless rows.map { |row| row.fetch("entry_id") }.uniq.sort == @entries.keys.sort && rows.map { |row| row.fetch("line_id") }.uniq.sort == @lines.keys.sort
        raise DataError.new("Pair similarity artifact does not match the fixed Entry or approved Line pool")
      end
      unless live_rows.length == 108 && live_rows.all? { |row| row.fetch("safety_classification") == "normal" }
        raise DataError.new("Issue 46 provider outputs must contain 108 normal outcomes")
      end
      completion = JSON.parse(File.read(completion_path("summary.json"), encoding: "UTF-8"))
      unless completion.fetch("pair_similarity_count") == EXPECTED_PAIR_COUNT && completion.dig("external_operation_counts", "embedding") == 1
        raise DataError.new("Entry Embedding completion summary is inconsistent")
      end
    end

    def load_pair_rows
      CSV.read(completion_path("pair_similarities.csv"), headers: true, encoding: "UTF-8").map(&:to_h)
    end

    def source_hashes
      {
        issue_46_provider_outputs_sha256: Digest::SHA256.file(issue_46_path("provider_outputs.jsonl")).hexdigest,
        issue_46_line_index_sha256: Digest::SHA256.file(issue_46_path("line_index.json")).hexdigest,
        completion_summary_sha256: Digest::SHA256.file(completion_path("summary.json")).hexdigest,
        completion_pair_similarities_sha256: Digest::SHA256.file(completion_path("pair_similarities.csv")).hexdigest,
        entries_sha256: Digest::SHA256.file(@configuration.path(:entries)).hexdigest,
        lines_sha256: Digest::SHA256.file(@configuration.path(:lines)).hexdigest
      }
    end

    def selection_headers
      %w[setting_id a_min s_max top_n entry_id repetition eligible_count selected_line_id status seed abstraction_similarity surface_similarity]
    end

    def percentile(values, fraction)
      return nil if values.empty?
      ordered = values.sort
      ordered.fetch([(ordered.length * fraction).ceil - 1, 0].max)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(6)
    end

    def blank_to_nil(value)
      value.to_s.empty? ? nil : value
    end

    def evaluation_path(filename)
      File.join(@configuration.root_dir, "data", "evaluations", filename)
    end

    def issue_46_path(filename)
      File.join(@issue_46_results_dir, filename)
    end

    def completion_path(filename)
      File.join(@completion_results_dir, filename)
    end

    def read_jsonl(path)
      File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
    end

    def write_jsonl(path, rows)
      File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n", mode: "w:UTF-8")
    end
  end
end
