# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module AiLineSelection
  class Telemetry
    ALLOWED_KEYS = %i[
      timestamp correlation_id operation status duration_ms provider model request_id
      input_units output_units estimated_cost_jpy error_code candidate_count
    ].freeze

    attr_reader :events

    def initialize(correlation_id:, path: nil)
      @correlation_id = correlation_id
      @path = path
      @events = []
    end

    def record(attributes)
      event = {
        timestamp: Time.now.utc.iso8601(6),
        correlation_id: @correlation_id
      }.merge(attributes).slice(*ALLOWED_KEYS)
      @events << event.freeze
      append(event) if @path
      event
    end

    def summary
      {
        correlation_id: @correlation_id,
        operations: events.count { |event| event[:operation] },
        errors: events.count { |event| event[:status] == "error" },
        duration_ms: events.sum { |event| event[:duration_ms].to_f }.round(2),
        input_units: events.sum { |event| event[:input_units].to_i },
        output_units: events.sum { |event| event[:output_units].to_i },
        estimated_cost_jpy: events.sum { |event| event[:estimated_cost_jpy].to_f }.round(4)
      }
    end

    private

    def append(event)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a:UTF-8") { |file| file.puts(JSON.generate(event)) }
    end
  end
end
