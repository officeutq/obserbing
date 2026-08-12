# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ai_line_selection"

module TestSupport
  def configuration
    @configuration ||= AiLineSelection::Configuration.load
  end

  def data_loader
    @data_loader ||= AiLineSelection::DataLoader.new(configuration)
  end
end

class Minitest::Test
  include TestSupport
end
