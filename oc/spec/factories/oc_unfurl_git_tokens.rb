# frozen_string_literal: true

FactoryBot.define do
  factory :oc_unfurl_git_token, class: 'OC::Authn::UnfurlGitToken' do
    user
    personal_access_token { association(:personal_access_token, user: user) }
    token { personal_access_token.token }
  end
end
