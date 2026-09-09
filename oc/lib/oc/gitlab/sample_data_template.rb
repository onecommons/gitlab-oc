# frozen_string_literal: true

module OC
  module Gitlab
    module SampleDataTemplate
      extend ActiveSupport::Concern

      class_methods do
        extend ::Gitlab::Utils::Override

        override :all
        def all
          []
        end
      end
    end
  end
end
