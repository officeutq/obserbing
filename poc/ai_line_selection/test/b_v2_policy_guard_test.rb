# frozen_string_literal: true

require_relative "test_helper"

class Bv2PolicyGuardTest < Minitest::Test
  PROFILE = "b-v2-profile-primary-secondary-v1"
  EMBEDDING = "b-v2-openai-small-dual-cosine-v1"

  def setup
    @guard = AiLineSelection::Bv2PolicyGuard.new(configuration: configuration)
  end

  def test_all_current_approved_lines_pass_approval_without_changing_pool
    decisions = data_loader.lines.select { |line| line.fetch("status") == "approved" }
                           .map { |line| @guard.approval_decision(line: line) }

    assert_equal 96, decisions.length
    assert decisions.all? { |decision| decision.fetch(:approved) }
  end

  def test_candidate_or_retired_line_is_not_runtime_eligible
    line = data_loader.lines.find { |item| item.fetch("status") != "approved" }
    decision = @guard.evaluate(
      entry: data_loader.entry("E001"), line: line,
      profile_version: PROFILE, embedding_version: EMBEDDING
    )

    assert_equal false, decision.fetch(:eligible)
    assert_includes decision.fetch(:exclusion_reasons), "status_not_approved"
  end

  def test_independent_analogical_facts_do_not_require_entry_evidence
    [%w[E001 L083], %w[E033 L102]].each do |entry_id, line_id|
      decision = @guard.evaluate(
        entry: data_loader.entry(entry_id), line: line(line_id),
        profile_version: PROFILE, embedding_version: EMBEDDING
      )

      assert_equal true, decision.fetch(:eligible), "#{entry_id}/#{line_id}"
      assert_equal false, decision.fetch(:independent_line_facts_required_in_entry)
    end
  end

  def test_required_runtime_claims_are_excluded
    AiLineSelection::Bv2PolicyGuard::CLAIM_TYPES.each do |claim|
      decision = @guard.evaluate(
        entry: data_loader.entry("E001"), line: line("L083"),
        profile_version: PROFILE, embedding_version: EMBEDDING,
        line_claims: [claim]
      )

      assert_equal false, decision.fetch(:eligible)
      assert_includes decision.fetch(:exclusion_reasons), "runtime_policy:#{claim}"
    end
  end

  def test_history_prevents_same_pair_and_recent_line_reuse
    history = [{ "entry_id" => "E001", "line_id" => "L083" }]
    decision = @guard.evaluate(
      entry: data_loader.entry("E001"), line: line("L083"),
      profile_version: PROFILE, embedding_version: EMBEDDING, history: history
    )

    assert_equal false, decision.fetch(:eligible)
    assert_includes decision.fetch(:exclusion_reasons), "history:same_entry_line_pair"
    assert_includes decision.fetch(:exclusion_reasons), "history:recent_line"
  end

  def test_version_mismatch_is_technical_error_not_silence
    assert_raises(AiLineSelection::ConfigurationError) do
      @guard.evaluate(
        entry: data_loader.entry("E001"), line: line("L083"),
        profile_version: "wrong", embedding_version: EMBEDDING
      )
    end
  end

  def test_valid_empty_result_is_semantic_silence
    candidate = { "line" => line("L083"), "line_claims" => ["user_fact_assertion"] }
    result = @guard.filter(
      entry: data_loader.entry("E001"), candidates: [candidate],
      profile_version: PROFILE, embedding_version: EMBEDDING
    )

    assert_equal "silence", result.fetch(:outcome)
    assert_equal "no_eligible_candidate_after_policy", result.fetch(:silence_reason)
    assert_equal false, result.fetch(:technical_error)
  end

  private

  def line(id)
    data_loader.lines.find { |item| item.fetch("id") == id }
  end
end
