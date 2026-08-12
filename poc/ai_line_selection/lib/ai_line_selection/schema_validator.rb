# frozen_string_literal: true

module AiLineSelection
  class SchemaValidator
    def validate!(operation, schema, value)
      errors = validate_node(schema, value, "$")
      raise SchemaValidationError.new(operation, errors) unless errors.empty?

      value
    end

    private

    def validate_node(schema, value, path)
      errors = []
      errors << "#{path}: must equal #{schema["const"].inspect}" if schema.key?("const") && value != schema["const"]
      errors << "#{path}: must be one of #{schema["enum"].inspect}" if schema.key?("enum") && !schema["enum"].include?(value)

      type = schema["type"]
      if type && !matches_type?(type, value)
        return errors << "#{path}: expected #{type}, got #{ruby_type(value)}"
      end

      case type
      when "object"
        validate_object(schema, value, path, errors)
      when "array"
        validate_array(schema, value, path, errors)
      when "string"
        validate_string(schema, value, path, errors)
      when "number", "integer"
        validate_number(schema, value, path, errors)
      end

      errors
    end

    def validate_object(schema, value, path, errors)
      properties = schema.fetch("properties", {})
      schema.fetch("required", []).each do |key|
        errors << "#{path}.#{key}: is required" unless value.key?(key)
      end

      if schema["additionalProperties"] == false
        (value.keys - properties.keys).each { |key| errors << "#{path}.#{key}: is not allowed" }
      end

      properties.each do |key, child_schema|
        next unless value.key?(key)

        errors.concat(validate_node(child_schema, value[key], "#{path}.#{key}"))
      end
    end

    def validate_array(schema, value, path, errors)
      errors << "#{path}: must have at least #{schema["minItems"]} items" if schema["minItems"] && value.length < schema["minItems"]
      errors << "#{path}: must have at most #{schema["maxItems"]} items" if schema["maxItems"] && value.length > schema["maxItems"]
      return unless schema["items"]

      value.each_with_index do |item, index|
        errors.concat(validate_node(schema["items"], item, "#{path}[#{index}]"))
      end
    end

    def validate_string(schema, value, path, errors)
      errors << "#{path}: is too short" if schema["minLength"] && value.length < schema["minLength"]
      errors << "#{path}: is too long" if schema["maxLength"] && value.length > schema["maxLength"]
      errors << "#{path}: has invalid format" if schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
    end

    def validate_number(schema, value, path, errors)
      errors << "#{path}: must be >= #{schema["minimum"]}" if schema.key?("minimum") && value < schema["minimum"]
      errors << "#{path}: must be <= #{schema["maximum"]}" if schema.key?("maximum") && value > schema["maximum"]
    end

    def matches_type?(type, value)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "number" then value.is_a?(Numeric)
      when "integer" then value.is_a?(Integer)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else false
      end
    end

    def ruby_type(value)
      value.nil? ? "null" : value.class.name
    end
  end
end
