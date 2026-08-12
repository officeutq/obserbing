# frozen_string_literal: true

require "json"
require "securerandom"
require "zlib"

module AiLineSelection
  module Adapters
    class Fixture < Base
      DIMENSIONS = 64

      def call(request)
        data = case request.operation
               when :safety then safety(request.fixture_context)
               when :meaning then meaning(request.fixture_context)
               when :embedding then embedding(request.input)
               when :line_evaluation then line_evaluation(request.input)
               else
                 raise ProviderContractError.new(
                   "Fixture does not support operation",
                   operation: request.operation
                 )
               end

        AdapterResponse.new(
          data: data,
          provider: "fixture",
          model: request.model,
          request_id: "fixture-#{SecureRandom.hex(6)}",
          usage: usage(request.input, data)
        )
      end

      private

      def safety(fixture_context)
        expected = fixture_context.fetch("expected")
        classification = expected.fetch("safety")
        {
          "schema_version" => "draft-1",
          "classification" => classification,
          "reason_code" => expected.fetch("reason_code", classification == "normal" ? "none" : "insufficient_context"),
          "confidence" => classification == "indeterminate" ? 0.5 : 0.99
        }
      end

      def meaning(fixture_context)
        expected = fixture_context.fetch("expected")
        {
          "schema_version" => "draft-1",
          "themes" => expected.fetch("themes"),
          "structure" => expected.fetch("structure"),
          "abstraction" => expected.fetch("abstraction")
        }
      end

      def embedding(input)
        {
          "schema_version" => "draft-1",
          "vectors" => input.fetch("texts").each_with_index.map do |text, index|
            { "index" => index, "values" => vectorize(text) }
          end
        }
      end

      def line_evaluation(input)
        {
          "schema_version" => "draft-1",
          "candidates" => input.fetch("candidates").map do |candidate|
            line = candidate.fetch("line")
            directness = line.fetch("directness").to_f
            {
              "line_id" => line.fetch("id"),
              "relevance" => clamp((candidate.fetch("similarity").to_f + 1.0) / 2.0),
              "directness" => clamp(directness),
              "space" => clamp(0.95 - (directness * 0.35)),
              "obserbing_fit" => line.fetch("review_status") == "reviewed" ? 0.9 : 0.65
            }
          end
        }
      end

      def vectorize(text)
        values = Array.new(DIMENSIONS, 0.0)
        text.split.each do |token|
          hash = Zlib.crc32(token.encode("UTF-8"))
          values[hash % DIMENSIONS] += hash.odd? ? 8.0 : -8.0
        end

        bytes = text.encode("UTF-8").bytes
        grams = bytes.each_cons(3).to_a
        grams = [bytes] if grams.empty?

        grams.each do |gram|
          hash = Zlib.crc32(gram.pack("C*"))
          index = hash % DIMENSIONS
          values[index] += hash.odd? ? 0.25 : -0.25
        end

        magnitude = Math.sqrt(values.sum { |value| value * value })
        return values if magnitude.zero?

        values.map { |value| (value / magnitude).round(8) }
      end

      def usage(input, output)
        Usage.new(
          input_units: (JSON.generate(input).length / 4.0).ceil,
          output_units: (JSON.generate(output).length / 4.0).ceil,
          estimated_cost_jpy: 0.0
        )
      end

      def clamp(value)
        [[value, 0.0].max, 1.0].min.round(4)
      end
    end
  end
end
