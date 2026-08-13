# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module AiLineSelection
  class Bv2PolicyGuard
    CLAIM_TYPES = %w[user_fact_assertion explicit_contradiction advice_or_diagnosis].freeze

    attr_reader :version

    def initialize(configuration:, policy_path: nil)
      @configuration = configuration
      @policy_path = File.expand_path(
        policy_path || File.join(configuration.root_dir, "data", "evaluations", "b_v2_guard_policy_v1.yml")
      )
      @policy = YAML.safe_load_file(@policy_path, permitted_classes: [], aliases: false)
      @version = @policy.fetch("version")
      validate_policy!
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("B-v2 guard policy is invalid", details: { error: e.class.name })
    end

    def approval_decision(line:)
      reasons = []
      reasons << "status_not_approved" unless line.fetch("status") == @policy.dig("line_approval", "required_status")
      flags = Array(line["policy_flags"]).map(&:to_s)
      prohibited = flags & @policy.dig("line_approval", "prohibited_flags")
      reasons.concat(prohibited.map { |flag| "approval_policy:#{flag}" })
      {
        line_id: line.fetch("id"),
        policy_version: version,
        approved: reasons.empty?,
        exclusion_reasons: reasons
      }
    end

    def evaluate(entry:, line:, profile_version:, embedding_version:, history: [], line_claims: [])
      validate_runtime_versions!(profile_version, embedding_version)
      approval = approval_decision(line: line)
      reasons = approval.fetch(:exclusion_reasons).dup
      claims = Array(line_claims).map(&:to_s)
      unknown_claims = claims - CLAIM_TYPES
      unless unknown_claims.empty?
        raise ConfigurationError.new("Unknown B-v2 policy claim type", details: { claim_types: unknown_claims })
      end
      reasons.concat(claims.map { |claim| "runtime_policy:#{claim}" })
      reasons.concat(history_reasons(entry.fetch("id"), line.fetch("id"), history))
      {
        entry_id: entry.fetch("id"),
        line_id: line.fetch("id"),
        policy_version: version,
        profile_version: profile_version,
        embedding_version: embedding_version,
        eligible: reasons.empty?,
        exclusion_reasons: reasons.uniq,
        independent_line_facts_required_in_entry: false
      }
    end

    def filter(entry:, candidates:, profile_version:, embedding_version:, history: [])
      decisions = candidates.map do |candidate|
        line = candidate.fetch("line")
        evaluate(
          entry: entry,
          line: line,
          profile_version: profile_version,
          embedding_version: embedding_version,
          history: history,
          line_claims: candidate.fetch("line_claims", [])
        )
      end
      eligible_ids = decisions.filter_map { |decision| decision.fetch(:line_id) if decision.fetch(:eligible) }
      {
        policy_version: version,
        eligible_line_ids: eligible_ids,
        exclusions: decisions.reject { |decision| decision.fetch(:eligible) },
        outcome: eligible_ids.empty? ? "silence" : "candidates",
        silence_reason: eligible_ids.empty? ? "no_eligible_candidate_after_policy" : nil,
        technical_error: false
      }
    end

    private

    def validate_policy!
      expected = @policy.dig("line_pool", "approved_id_text_status_canonical_sha256")
      actual = approved_line_pool_hash
      unless expected == actual
        raise DataError.new("B-v2 policy Line pool hash mismatch", details: { expected: expected, actual: actual })
      end
      raise DataError.new("B-v2 policy must not inherit combined_v1") if @policy.dig("regressions", "old_combined_v1_inherited")
    end

    def approved_line_pool_hash
      lines = DataLoader.new(@configuration).lines.select { |line| line.fetch("status") == "approved" }
                        .sort_by { |line| line.fetch("id") }
                        .map { |line| line.slice("id", "text", "status") }
      Digest::SHA256.hexdigest(JSON.generate(lines))
    end

    def validate_runtime_versions!(profile_version, embedding_version)
      expected_profile = @policy.dig("versions", "profile")
      expected_embedding = @policy.dig("versions", "embedding")
      return if profile_version == expected_profile && embedding_version == expected_embedding

      raise ConfigurationError.new(
        "B-v2 runtime artifact version mismatch",
        details: {
          expected_profile: expected_profile,
          actual_profile: profile_version,
          expected_embedding: expected_embedding,
          actual_embedding: embedding_version
        }
      )
    end

    def history_reasons(entry_id, line_id, history)
      rows = Array(history)
      reasons = []
      if rows.any? { |row| row.fetch("entry_id", nil) == entry_id && row.fetch("line_id", nil) == line_id }
        reasons << "history:same_entry_line_pair"
      end
      window = Integer(@policy.dig("history", "recent_line_window"))
      recent = rows.last(window)
      reasons << "history:recent_line" if recent.any? { |row| row.fetch("line_id", nil) == line_id }
      reasons
    end
  end
end
