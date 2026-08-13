# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "data")
EVALUATIONS = File.join(DATA, "evaluations")
RESULTS = File.join(ROOT, "results")

RUBRIC_PATH = File.join(EVALUATIONS, "reflective_distance_rubric_v1.yml")
JUDGMENTS_PATH = File.join(EVALUATIONS, "reflective_distance_codex_judgments_v1.csv")
DISPLAY_PATH = File.join(EVALUATIONS, "reflective_distance_display_pairs_v1.csv")
PREVIOUS_PATH = File.join(EVALUATIONS, "reflective_distance_previous_labels_v1.csv")
SUMMARY_PATH = File.join(EVALUATIONS, "reflective_distance_reassessment_v1.yml")

LIVE_DIR = File.join(RESULTS, "abstraction_only_integrated_live_20260813_issue36")
BASELINE_DIR = File.join(RESULTS, "integrated_20260812T214607Z_d506")

def load_yaml(path)
  YAML.safe_load_file(path, permitted_classes: [], aliases: false)
end

def jsonl(path)
  File.readlines(path, encoding: "UTF-8").map { |line| JSON.parse(line) }
end

def bool(value)
  value == true || value.to_s == "true"
end

def rate(count, total)
  total.zero? ? 0.0 : (count.to_f / total).round(4)
end

def sha256(path, normalize_text: false)
  content = File.binread(path)
  content = content.gsub("\r\n", "\n") if normalize_text
  Digest::SHA256.hexdigest(content)
end

def write_csv(path, headers, rows)
  CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
    rows.each { |row| csv << headers.map { |header| row.fetch(header) } }
  end
end

entries_path = File.join(DATA, "entries.yml")
lines_path = File.join(DATA, "lines.yml")
entries = load_yaml(entries_path).fetch("entries").to_h { |entry| [entry.fetch("id"), entry.fetch("body")] }
lines = load_yaml(lines_path).fetch("lines").to_h { |line| [line.fetch("id"), line.fetch("text")] }
judgments = CSV.read(JUDGMENTS_PATH, headers: true, encoding: "UTF-8").to_h do |row|
  [row.fetch("pair_id"), row.to_h]
end

live_candidates_path = File.join(LIVE_DIR, "candidate_sets.jsonl")
live_quality_path = File.join(LIVE_DIR, "offline_quality_outputs.jsonl")
baseline_provider_path = File.join(BASELINE_DIR, "provider_outputs.jsonl")
baseline_human_path = File.join(BASELINE_DIR, "human_evaluation.csv")
baseline_mapping_path = File.join(BASELINE_DIR, "blind_mapping.csv")

live_candidates = jsonl(live_candidates_path)
baseline_provider = jsonl(baseline_provider_path).select { |record| record.fetch("status") == "line" }
baseline_human = CSV.read(baseline_human_path, headers: true, encoding: "UTF-8")
baseline_mapping = CSV.read(baseline_mapping_path, headers: true, encoding: "UTF-8").to_h do |row|
  [row.fetch("blind_id"), row]
end
baseline_blind_keys = baseline_human.to_h do |row|
  mapping = baseline_mapping.fetch(row.fetch("blind_id"))
  [[row.fetch("entry_id"), Integer(mapping.fetch("repetition")), row.fetch("selected_line_id")], row]
end

display_rows = live_candidates.map do |record|
  {
    "dataset" => "abstraction_only_issue36",
    "display_id" => format("A-%s-R%d", record.fetch("entry_id"), record.fetch("repetition")),
    "entry_id" => record.fetch("entry_id"),
    "repetition" => record.fetch("repetition"),
    "line_id" => record.fetch("selected_line_id"),
    "blind_sample" => true
  }
end

display_rows.concat(baseline_provider.map do |record|
  key = [record.fetch("entry_id"), record.fetch("repetition"), record.fetch("ai_line_id")]
  {
    "dataset" => "selected_v1_all_line_displays",
    "display_id" => format("B-%s-R%d", record.fetch("entry_id"), record.fetch("repetition")),
    "entry_id" => record.fetch("entry_id"),
    "repetition" => record.fetch("repetition"),
    "line_id" => record.fetch("ai_line_id"),
    "blind_sample" => baseline_blind_keys.key?(key)
  }
end)

display_headers = %w[dataset display_id entry_id repetition line_id blind_sample]
write_csv(DISPLAY_PATH, display_headers, display_rows)

live_old_by_key = jsonl(live_quality_path).to_h do |record|
  [[record.fetch("entry_id"), record.fetch("rank"), record.fetch("line_id")], record]
end
critical_review_path = File.join(EVALUATIONS, "integrated_live_codex_review_v1.yml")
critical_reviews = load_yaml(critical_review_path).fetch("reviews").to_h do |review|
  [[review.fetch("entry_id"), review.fetch("line_id")], review]
end

previous_rows = display_rows.filter_map do |display|
  if display.fetch("dataset") == "abstraction_only_issue36"
    old = live_old_by_key.fetch([
      display.fetch("entry_id"), display.fetch("repetition"), display.fetch("line_id")
    ])
    correction = critical_reviews[[display.fetch("entry_id"), display.fetch("line_id")]]
    {
      "dataset" => display.fetch("dataset"),
      "display_id" => display.fetch("display_id"),
      "entry_id" => display.fetch("entry_id"),
      "repetition" => display.fetch("repetition"),
      "line_id" => display.fetch("line_id"),
      "old_acceptable" => correction ? correction.fetch("acceptable") : old.fetch("acceptable"),
      "old_distance" => correction ? correction.fetch("distance") : old.fetch("distance"),
      "old_clearly_unrelated" => correction ? correction.fetch("clearly_unrelated") : old.fetch("clearly_unrelated"),
      "old_fatal_grounding_mismatch" => correction ? correction.fetch("fatal_grounding_mismatch") : old.fetch("fatal_grounding_mismatch"),
      "old_judge" => correction ? "openai_blind_preliminary_plus_codex_critical_review" : old.fetch("judge")
    }
  elsif display.fetch("blind_sample")
    old = baseline_blind_keys.fetch([
      display.fetch("entry_id"), display.fetch("repetition"), display.fetch("line_id")
    ])
    fatal = old.fetch("fatal_violation").to_s
    {
      "dataset" => "selected_v1_blind_sample",
      "display_id" => display.fetch("display_id"),
      "entry_id" => display.fetch("entry_id"),
      "repetition" => display.fetch("repetition"),
      "line_id" => display.fetch("line_id"),
      "old_acceptable" => bool(old.fetch("acceptable")),
      "old_distance" => old.fetch("distance_rating"),
      "old_clearly_unrelated" => false,
      "old_fatal_grounding_mismatch" => !fatal.empty? && fatal != "none",
      "old_judge" => old.fetch("judge")
    }
  end
end

previous_headers = %w[
  dataset display_id entry_id repetition line_id old_acceptable old_distance
  old_clearly_unrelated old_fatal_grounding_mismatch old_judge
]
write_csv(PREVIOUS_PATH, previous_headers, previous_rows)

def joined_review(display, judgments, entries, lines)
  pair_id = "#{display.fetch('entry_id')}/#{display.fetch('line_id')}"
  judgment = judgments.fetch(pair_id)
  display.merge(
    "pair_id" => pair_id,
    "entry_text" => entries.fetch(display.fetch("entry_id")),
    "line_text" => lines.fetch(display.fetch("line_id")),
    "acceptable" => bool(judgment.fetch("acceptable")),
    "distance" => judgment.fetch("distance"),
    "relation_type" => judgment.fetch("relation_type"),
    "user_fact_assertion" => bool(judgment.fetch("user_fact_assertion")),
    "explicit_contradiction" => bool(judgment.fetch("explicit_contradiction")),
    "advice_or_diagnosis" => bool(judgment.fetch("advice_or_diagnosis")),
    "clearly_unrelated" => bool(judgment.fetch("clearly_unrelated")),
    "confidence" => judgment.fetch("confidence"),
    "reason" => judgment.fetch("reason")
  )
end

all_reviews = display_rows.map { |display| joined_review(display, judgments, entries, lines) }
live_reviews = all_reviews.select { |review| review.fetch("dataset") == "abstraction_only_issue36" }
baseline_all_reviews = all_reviews.select { |review| review.fetch("dataset") == "selected_v1_all_line_displays" }
baseline_sample_reviews = baseline_all_reviews.select { |review| review.fetch("blind_sample") }

def summarize(reviews)
  acceptable = reviews.count { |review| review.fetch("acceptable") }
  analogies = reviews.select { |review| review.fetch("relation_type") == "analogical_transfer" }
  confirmed = reviews.reject { |review| review.fetch("confidence") == "low" }
  confirmed_acceptable = confirmed.count { |review| review.fetch("acceptable") }
  {
    "evaluated_count" => reviews.length,
    "unique_pair_count" => reviews.map { |review| review.fetch("pair_id") }.uniq.length,
    "acceptable_count" => acceptable,
    "acceptable_rate" => rate(acceptable, reviews.length),
    "distance_counts" => reviews.map { |review| review.fetch("distance") }.tally.sort.to_h,
    "relation_type_counts" => reviews.map { |review| review.fetch("relation_type") }.tally.sort.to_h,
    "analogical_transfer_count" => analogies.length,
    "analogical_transfer_acceptable_count" => analogies.count { |review| review.fetch("acceptable") },
    "analogical_transfer_acceptable_rate" => rate(analogies.count { |review| review.fetch("acceptable") }, analogies.length),
    "same_domain_count" => reviews.count { |review| review.fetch("relation_type") == "same_domain" },
    "user_fact_assertion_count" => reviews.count { |review| review.fetch("user_fact_assertion") },
    "explicit_contradiction_count" => reviews.count { |review| review.fetch("explicit_contradiction") },
    "advice_or_diagnosis_count" => reviews.count { |review| review.fetch("advice_or_diagnosis") },
    "clearly_unrelated_count" => reviews.count { |review| review.fetch("clearly_unrelated") },
    "clearly_unrelated_rate" => rate(reviews.count { |review| review.fetch("clearly_unrelated") }, reviews.length),
    "low_confidence_count" => reviews.count { |review| review.fetch("confidence") == "low" },
    "confirmed_only" => {
      "evaluated_count" => confirmed.length,
      "acceptable_count" => confirmed_acceptable,
      "acceptable_rate" => rate(confirmed_acceptable, confirmed.length)
    }
  }
end

previous_by_display = previous_rows.to_h { |row| [row.fetch("display_id"), row] }

def transitions(reviews, previous_by_display)
  compared = reviews.filter_map do |review|
    old = previous_by_display[review.fetch("display_id")]
    old && [review, old]
  end
  select_ids = lambda do |&block|
    compared.select(&block).map { |review, _old| review.fetch("display_id") }
  end
  changed = select_ids.call do |review, old|
    bool(old.fetch("old_acceptable")) != review.fetch("acceptable") ||
      old.fetch("old_distance") != review.fetch("distance")
  end
  acceptable_changed = select_ids.call do |review, old|
    bool(old.fetch("old_acceptable")) != review.fetch("acceptable")
  end
  distance_changed = select_ids.call { |review, old| old.fetch("old_distance") != review.fetch("distance") }
  old_too_close_to_acceptable = select_ids.call do |review, old|
    old.fetch("old_distance") == "too_close" && review.fetch("acceptable")
  end
  old_too_far_to_acceptable = select_ids.call do |review, old|
    old.fetch("old_distance") == "too_far" && review.fetch("acceptable")
  end
  old_fatal_to_analogy = select_ids.call do |review, old|
    bool(old.fetch("old_fatal_grounding_mismatch")) && review.fetch("relation_type") == "analogical_transfer"
  end
  old_acceptable_to_unacceptable = select_ids.call do |review, old|
    bool(old.fetch("old_acceptable")) && !review.fetch("acceptable")
  end
  {
    "compared_count" => compared.length,
    "any_acceptable_or_distance_change_count" => changed.length,
    "acceptable_changed_count" => acceptable_changed.length,
    "distance_changed_count" => distance_changed.length,
    "old_too_close_to_new_acceptable_count" => old_too_close_to_acceptable.length,
    "old_too_close_to_new_acceptable_display_ids" => old_too_close_to_acceptable,
    "old_too_far_to_new_acceptable_count" => old_too_far_to_acceptable.length,
    "old_too_far_to_new_acceptable_display_ids" => old_too_far_to_acceptable,
    "old_fatal_to_new_analogical_transfer_count" => old_fatal_to_analogy.length,
    "old_fatal_to_new_analogical_transfer_display_ids" => old_fatal_to_analogy,
    "old_acceptable_to_new_unacceptable_count" => old_acceptable_to_unacceptable.length,
    "old_acceptable_to_new_unacceptable_display_ids" => old_acceptable_to_unacceptable
  }
end

def case_record(pair_id, all_reviews, previous_by_display)
  review = all_reviews.find { |item| item.fetch("pair_id") == pair_id }
  raise "Missing representative case #{pair_id}" unless review

  old = previous_by_display[review.fetch("display_id")]
  {
    "pair_id" => pair_id,
    "display_id" => review.fetch("display_id"),
    "entry_text" => review.fetch("entry_text"),
    "line_text" => review.fetch("line_text"),
    "old_acceptable" => old && bool(old.fetch("old_acceptable")),
    "old_distance" => old && old.fetch("old_distance"),
    "old_fatal_grounding_mismatch" => old && bool(old.fetch("old_fatal_grounding_mismatch")),
    "new_acceptable" => review.fetch("acceptable"),
    "new_distance" => review.fetch("distance"),
    "new_relation_type" => review.fetch("relation_type"),
    "new_user_fact_assertion" => review.fetch("user_fact_assertion"),
    "new_confidence" => review.fetch("confidence"),
    "reason" => review.fetch("reason")
  }
end

live_summary = summarize(live_reviews)
baseline_sample_summary = summarize(baseline_sample_reviews)
baseline_all_summary = summarize(baseline_all_reviews)
live_transitions = transitions(live_reviews, previous_by_display)
baseline_transitions = transitions(baseline_sample_reviews, previous_by_display)

low_confidence_cases = live_reviews.select { |review| review.fetch("confidence") == "low" }
  .group_by { |review| review.fetch("pair_id") }
  .map do |pair_id, reviews|
    first = reviews.first
    {
      "pair_id" => pair_id,
      "display_ids" => reviews.map { |review| review.fetch("display_id") },
      "entry_text" => first.fetch("entry_text"),
      "line_text" => first.fetch("line_text"),
      "provisional_acceptable" => first.fetch("acceptable"),
      "provisional_distance" => first.fetch("distance"),
      "provisional_relation_type" => first.fetch("relation_type"),
      "reason" => first.fetch("reason")
    }
  end

summary = {
  "version" => 1,
  "evaluation_version" => "reflective-distance-reassessment-v1",
  "rubric_id" => "reflective-distance-v1",
  "judge" => "codex_reassessment",
  "status" => "codex_reassessment_complete_human_review_pending",
  "created_at" => "2026-08-13",
  "issue" => 38,
  "audit" => {
    "rubric_frozen_commit" => "51b398f",
    "blind_judgments_initial_commit" => "ccd13e9",
    "baseline_expansion_commit" => "6794b76",
    "old_labels_joined_after_blind_judgment_commits" => true
  },
  "execution" => {
    "type" => "offline_existing_artifact_reassessment",
    "external_ai_api_calls" => 0,
    "embedding_api_calls" => 0,
    "safety_calls" => 0,
    "abstraction_calls" => 0,
    "line_reselection_calls" => 0
  },
  "datasets" => {
    "abstraction_only_issue36" => live_summary,
    "selected_v1_blind_sample_32" => baseline_sample_summary,
    "selected_v1_all_stored_line_displays_98" => baseline_all_summary
  },
  "old_to_new" => {
    "abstraction_only_issue36" => live_transitions,
    "selected_v1_blind_sample_32" => baseline_transitions
  },
  "comparison" => {
    "abstraction_only_acceptable_rate" => live_summary.fetch("acceptable_rate"),
    "selected_v1_all_stored_acceptable_rate" => baseline_all_summary.fetch("acceptable_rate"),
    "delta_percentage_points" => ((live_summary.fetch("acceptable_rate") - baseline_all_summary.fetch("acceptable_rate")) * 100).round(2),
    "direct_comparison_limitation" =>
      "The datasets have different display counts, blocked Entry coverage, and selection " \
      "distributions. The 32-record historical blind sample is smaller still, so these " \
      "rates compare the same rubric but are not a controlled head-to-head experiment."
  },
  "acceptance" => {
    "required_rate" => 0.90,
    "abstraction_only_met" => live_summary.fetch("acceptable_rate") >= 0.90,
    "confirmed_only_met" => live_summary.dig("confirmed_only", "acceptable_rate") >= 0.90
  },
  "representative_cases" => {
    "e001_l083" => case_record("E001/L083", live_reviews, previous_by_display),
    "e033_l102" => case_record("E033/L102", baseline_sample_reviews, previous_by_display),
    "cross_domain_reflection" => case_record("E024/L076", live_reviews, previous_by_display),
    "clear_unrelated" => case_record("E006/L044", live_reviews, previous_by_display),
    "clear_direct_restatement" => case_record("E001/L001", live_reviews, previous_by_display)
  },
  "human_review" => {
    "required" => !low_confidence_cases.empty?,
    "display_count" => live_summary.fetch("low_confidence_count"),
    "unique_pair_count" => low_confidence_cases.length,
    "cases" => low_confidence_cases
  },
  "decision" => {
    "old_fatal_interpretation_revised" => true,
    "relative_ranking_changed_in_favor_of_abstraction_only" => true,
    "production_candidate" => false,
    "reopen_epic_27" => false,
    "previous_non_adoption_reversed" => false,
    "reason" =>
      "The new rubric validates some cross-domain analogies that the previous grounding " \
      "framing penalized, and abstraction-only scores above selected-v1 under this rubric. " \
      "It still reaches only 50% provisional acceptance, fails the fixed 90% threshold, " \
      "and has unresolved low-confidence cases, so the prior non-adoption remains."
  },
  "record_join" => {
    "display_pairs" => File.basename(DISPLAY_PATH),
    "pair_judgments" => File.basename(JUDGMENTS_PATH),
    "previous_labels" => File.basename(PREVIOUS_PATH),
    "join_key" => "entry_id/line_id for judgments; display_id for previous labels"
  },
  "source_hashes" => {
    "rubric_sha256" => sha256(RUBRIC_PATH, normalize_text: true),
    "judgments_sha256" => sha256(JUDGMENTS_PATH, normalize_text: true),
    "display_pairs_sha256" => sha256(DISPLAY_PATH, normalize_text: true),
    "previous_labels_sha256" => sha256(PREVIOUS_PATH, normalize_text: true),
    "entries_sha256" => sha256(entries_path, normalize_text: true),
    "lines_sha256" => sha256(lines_path, normalize_text: true),
    "live_candidate_sets_sha256" => sha256(live_candidates_path),
    "live_previous_quality_sha256" => sha256(live_quality_path),
    "baseline_provider_outputs_sha256" => sha256(baseline_provider_path),
    "baseline_human_evaluation_sha256" => sha256(baseline_human_path)
  }
}

File.write(SUMMARY_PATH, YAML.dump(summary), mode: "w", encoding: "UTF-8")
puts "Wrote #{DISPLAY_PATH}"
puts "Wrote #{PREVIOUS_PATH}"
puts "Wrote #{SUMMARY_PATH}"
