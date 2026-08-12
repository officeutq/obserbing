# frozen_string_literal: true

module AiLineSelection
  class EnvironmentLoader
    KEYS = %w[OPENAI_API_KEY ANTHROPIC_API_KEY].freeze

    def self.load(root_dir:, environment: ENV, filename: ".env")
      path = File.join(root_dir, filename)
      return environment unless File.file?(path)

      File.foreach(path, encoding: "bom|utf-8") do |line|
        match = line.match(/\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/)
        next unless match

        key = match[1]
        next unless KEYS.include?(key)
        next if environment.key?(key)

        environment[key] = unquote(match[2])
      end
      environment
    end

    def self.unquote(value)
      return value[1...-1] if value.length >= 2 && value.start_with?("'") && value.end_with?("'")
      return value[1...-1].gsub('\\n', "\n").gsub('\\"', '"') if value.length >= 2 && value.start_with?('"') && value.end_with?('"')

      value.sub(/\s+#.*\z/, "")
    end
    private_class_method :unquote
  end
end
