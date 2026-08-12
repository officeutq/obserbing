# frozen_string_literal: true

require "yaml"

module AiLineSelection
  class DataLoader
    def initialize(configuration)
      @configuration = configuration
    end

    def entries
      @entries ||= load_collection(:entries, "entries", /^E\d{3}$/)
    end

    def lines
      @lines ||= load_collection(:lines, "lines", /^L\d{3}$/)
    end

    def safety_cases
      @safety_cases ||= load_collection(:safety_cases, "cases", /^S\d{3}$/)
    end

    def entry(id)
      entries.find { |item| item.fetch("id") == id } ||
        raise(DataError.new("Entry was not found", details: { id: id }))
    end

    private

    def load_collection(path_name, collection_key, id_pattern)
      path = @configuration.path(path_name)
      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      collection = document.fetch(collection_key)
      unless collection.is_a?(Array) && !collection.empty?
        raise DataError.new("Dataset collection must be a non-empty array", details: { path: path, key: collection_key })
      end

      ids = collection.map { |item| item.fetch("id") }
      duplicate_ids = ids.tally.select { |_id, count| count > 1 }.keys
      raise DataError.new("Dataset IDs must be unique", details: { duplicate_ids: duplicate_ids }) unless duplicate_ids.empty?

      invalid_ids = ids.reject { |id| id_pattern.match?(id) }
      raise DataError.new("Dataset has invalid IDs", details: { invalid_ids: invalid_ids }) unless invalid_ids.empty?

      validate_records!(path_name, collection)
      collection.freeze
    rescue Errno::ENOENT => e
      raise DataError.new("Dataset file was not found", details: { path: e.path })
    rescue Psych::Exception, KeyError => e
      raise DataError.new("Dataset YAML is invalid", details: { path: path, error: e.class.name })
    end

    def validate_records!(path_name, collection)
      collection.each do |record|
        case path_name.to_sym
        when :entries, :safety_cases
          validate_entry!(record)
        when :lines
          validate_line!(record)
        end
      end
    end

    def validate_entry!(record)
      raise KeyError unless record.fetch("body").is_a?(String) && !record.fetch("body").empty?

      expected = record.fetch("expected")
      unless %w[normal safety indeterminate].include?(expected.fetch("safety"))
        raise KeyError
      end
      raise KeyError unless expected.fetch("themes").is_a?(Array) && !expected.fetch("themes").empty?

      %w[reason_code structure abstraction].each { |key| raise KeyError unless expected.fetch(key).is_a?(String) }
    end

    def validate_line!(record)
      %w[text theme meaning source review_status].each do |key|
        raise KeyError unless record.fetch(key).is_a?(String) && !record.fetch(key).empty?
      end

      raise KeyError unless %w[approved candidate retired].include?(record.fetch("status"))

      directness = record.fetch("directness")
      raise KeyError unless directness.is_a?(Numeric) && directness.between?(0, 1)
    end
  end
end
