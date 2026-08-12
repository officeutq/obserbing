# frozen_string_literal: true

module AiLineSelection
  module Adapters
    class Base
      def call(_request)
        raise NotImplementedError
      end
    end
  end
end
