# frozen_string_literal: true

module OC
  module Onboarding
    # Invite codes live in instance CI variables so they can change without a
    # deploy: UNFURL_VALID_INVITE_CODES is a list, UNFURL_APPROVE_MATCHING_CODES
    # a regular expression whose matches also skip approval and confirmation.
    module InviteCodes
      VALID_KEY = 'UNFURL_VALID_INVITE_CODES'
      APPROVE_KEY = 'UNFURL_APPROVE_MATCHING_CODES'
      SEPARATOR = /[\s;,]+/

      class << self
        def valid?(code)
          code.present? && all.include?(code)
        end

        def approves_without_confirmation?(code)
          pattern = variable(APPROVE_KEY)

          code.present? && pattern.present? && Regexp.new(pattern).match?(code)
        end

        private

        def all
          (variable(VALID_KEY) || '').split(SEPARATOR)
        end

        def variable(key)
          ::Ci::InstanceVariable.all_cached.find { |variable| variable.key == key }&.value
        end
      end
    end
  end
end
