# frozen_string_literal: true

module OC
  module Authn
    # OC Change -- the git token a user, or the cloudmap's project bot, hands
    # the Unfurl server (OC::Authn::UnfurlGitTokenService). Kept so the next
    # request reuses it, encrypted so a database dump or backup holds no live
    # write token.
    class UnfurlGitToken < ApplicationRecord
      self.table_name = 'oc_unfurl_git_tokens'

      belongs_to :user, class_name: '::User'
      # No constraint in the database: personal_access_tokens is in another schema.
      belongs_to :personal_access_token, class_name: '::PersonalAccessToken'

      encrypts :token

      # Rails' own recommendation for an encrypted column.
      validates :token, presence: true, length: { maximum: 2048 }
    end
  end
end
