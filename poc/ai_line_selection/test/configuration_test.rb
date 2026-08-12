# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  def test_external_api_is_disabled_by_default
    refute configuration.external_api_enabled?
    assert_equal 5000, configuration.external_api.fetch("total_budget_jpy")
  end

  def test_each_operation_uses_fixture
    %i[safety meaning embedding line_evaluation].each do |operation|
      assert_equal "fixture", configuration.operation(operation).fetch("adapter")
    end
  end

  def test_safe_configuration_does_not_contain_api_key
    refute_includes configuration.to_safe_h.to_s, ENV.fetch("OBSERBING_AI_API_KEY", "not-configured-secret")
  end
end
