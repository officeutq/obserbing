# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class EnvironmentLoaderTest < Minitest::Test
  def test_os_environment_wins_and_dotenv_fills_missing_values
    Dir.mktmpdir do |directory|
      File.write(
        File.join(directory, ".env"),
        "OPENAI_API_KEY=dotenv-openai\nANTHROPIC_API_KEY='dotenv-anthropic'\n",
        mode: "w:UTF-8"
      )
      environment = { "OPENAI_API_KEY" => "os-openai" }

      AiLineSelection::EnvironmentLoader.load(root_dir: directory, environment: environment)

      assert_equal "os-openai", environment.fetch("OPENAI_API_KEY")
      assert_equal "dotenv-anthropic", environment.fetch("ANTHROPIC_API_KEY")
    end
  end
end
