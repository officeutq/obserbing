# frozen_string_literal: true

require_relative "ai_line_selection/errors"
require_relative "ai_line_selection/types"
require_relative "ai_line_selection/environment_loader"
require_relative "ai_line_selection/configuration"
require_relative "ai_line_selection/schema_validator"
require_relative "ai_line_selection/schema_registry"
require_relative "ai_line_selection/prompt_registry"
require_relative "ai_line_selection/data_loader"
require_relative "ai_line_selection/request_builder"
require_relative "ai_line_selection/telemetry"
require_relative "ai_line_selection/pricing_calculator"
require_relative "ai_line_selection/http_transport"
require_relative "ai_line_selection/adapters/base"
require_relative "ai_line_selection/adapters/fixture"
require_relative "ai_line_selection/adapters/pending_external"
require_relative "ai_line_selection/adapters/external_support"
require_relative "ai_line_selection/adapters/openai"
require_relative "ai_line_selection/adapters/anthropic"
require_relative "ai_line_selection/adapter_factory"
require_relative "ai_line_selection/operation_client"
require_relative "ai_line_selection/candidate_search"
require_relative "ai_line_selection/final_selector"
require_relative "ai_line_selection/runner"
require_relative "ai_line_selection/evaluator"
require_relative "ai_line_selection/meaning_comparison"
require_relative "ai_line_selection/doctor"
require_relative "ai_line_selection/cli"

module AiLineSelection
  ROOT = File.expand_path("..", __dir__)
end
