# frozen_string_literal: true

module Types
  module OC
    module Projects
      class UnfurlTypeEnum < BaseEnum
        graphql_name 'OCUnfurlType'
        description 'How a project is classified by the Unfurl files it holds.'

        value 'BLUEPRINT', value: ::OC::UNFURL_BLUEPRINT, description: 'Application blueprint.'
        value 'DASHBOARD', value: ::OC::UNFURL_DASHBOARD, description: "Someone's home dashboard."
        value 'REGULAR', value: ::OC::REGULAR_PROJECT, description: 'Neither: an ordinary project.'
      end
    end
  end
end
