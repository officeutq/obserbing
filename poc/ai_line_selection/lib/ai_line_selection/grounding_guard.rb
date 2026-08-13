# frozen_string_literal: true

require "yaml"

module AiLineSelection
  class GroundingGuard
    RULE_VERSION = "grounding-guard-v1"
    STRATEGIES = %w[shadow_line reviewed_attributes static_detection combined_v1].freeze
    CATEGORIES = %w[quantity person object event place_time strong_causality].freeze

    TOKEN_RULES = {
      "person" => {
        "friend" => /友人|友だち|友達/,
        "teacher" => /先生/,
        "coworker" => /同僚/,
        "boss" => /上司/,
        "family" => /家族|母|父|姉|兄|妹|弟/
      },
      "object" => {
        "box" => /箱/,
        "store" => /店/,
        "usual_light" => /いつもの(?:灯り|明かり)|いつも明るかった/,
        "key" => /鍵/,
        "desk" => /机/,
        "seat" => /席/
      },
      "event" => {
        "failure_occurred" => /失敗/,
        "meeting_completed" => /会議.{0,12}(?:終わ|終え)/,
        "completion" => /終えた|終わった|終えられた/,
        "unstarted" => /始めなかった|着手しなかった/,
        "store_closed" => /店.{0,8}閉|閉じた店/,
        "object_kept" => /捨てなかった|箱に入れてある/
      },
      "place_time" => {
        "route" => /帰り道|道.{0,8}(?:長|短)/,
        "room" => /部屋/,
        "morning" => /朝/,
        "night" => /夜/,
        "today" => /今日/
      }
    }.freeze

    QUANTITY_PATTERN = /(?:[0-9０-９一二三四五六七八九十百]+)(?:つ|個|件|人|回|本|枚|目)/
    CAUSALITY_PATTERN = /(?:だった|なかった|した|できない|大きかった)(?:から|ので|ため)/

    attr_reader :attribute_version

    def initialize(attributes_path:)
      document = YAML.safe_load_file(attributes_path, permitted_classes: [], aliases: false)
      @attribute_version = document.fetch("version")
      @rule_version = document.fetch("rule_version")
      raise DataError.new("Grounding rule version is unsupported") unless @rule_version == RULE_VERSION

      @line_attributes = document.fetch("lines")
      @entry_attributes = document.fetch("entries")
      @shadow_lines = document.fetch("shadow_lines")
    rescue Errno::ENOENT, Psych::Exception, KeyError => e
      raise DataError.new("Grounding attributes are invalid", details: { error: e.class.name })
    end

    def evaluate(entry:, line:, strategy: "combined_v1")
      raise ConfigurationError.new("Unknown grounding strategy", details: { strategy: strategy }) unless STRATEGIES.include?(strategy)

      line_text = strategy == "shadow_line" ? @shadow_lines.fetch(line["id"], line.fetch("text")) : line.fetch("text")
      requirements, evidence = facts_for(strategy, entry, line, line_text)
      missing = CATEGORIES.each_with_object({}) do |category, result|
        absent = requirements.fetch(category, []) - evidence.fetch(category, [])
        result[category] = absent unless absent.empty?
      end

      {
        rule_version: @rule_version,
        attribute_version: @attribute_version,
        strategy: strategy,
        entry_id: entry["id"],
        line_id: line["id"],
        compatible: missing.empty?,
        exclusion_reasons: missing.sort.map { |category, values| "#{category}:missing:#{values.sort.join(',')}" },
        requirements: requirements,
        evidence: evidence,
        shadow_applied: strategy == "shadow_line" && line_text != line.fetch("text")
      }
    end

    private

    def facts_for(strategy, entry, line, line_text)
      case strategy
      when "shadow_line"
        [detect(line_text), detect(entry.fetch("body"))]
      when "reviewed_attributes"
        [normalized_attributes(@line_attributes.fetch(line["id"], {})),
         normalized_attributes(@entry_attributes.fetch(entry["id"], {}))]
      when "static_detection"
        [detect(line_text), detect(entry.fetch("body"))]
      when "combined_v1"
        [merge_facts(detect(line_text), normalized_attributes(@line_attributes.fetch(line["id"], {}))),
         merge_facts(detect(entry.fetch("body")), normalized_attributes(@entry_attributes.fetch(entry["id"], {})))]
      end
    end

    def detect(text)
      facts = empty_facts
      facts["quantity"] << "quantity_present" if QUANTITY_PATTERN.match?(text)
      facts["strong_causality"] << "causal_relation_present" if CAUSALITY_PATTERN.match?(text)
      TOKEN_RULES.each do |category, rules|
        rules.each { |token, pattern| facts.fetch(category) << token if pattern.match?(text) }
      end
      facts.transform_values { |values| values.uniq.sort }
    end

    def normalized_attributes(attributes)
      empty_facts.merge(attributes.transform_values { |values| Array(values).map(&:to_s).uniq.sort })
    end

    def merge_facts(*sets)
      CATEGORIES.to_h do |category|
        [category, sets.flat_map { |set| set.fetch(category, []) }.uniq.sort]
      end
    end

    def empty_facts
      CATEGORIES.to_h { |category| [category, []] }
    end
  end
end
