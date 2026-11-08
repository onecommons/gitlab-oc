# frozen_string_literal: true

require 'spec_helper'

RSpec.describe API::UnfurlAccessToken, feature_category: :system_access do
  let_it_be(:user) { create(:user) }
  let(:api_token) { create(:personal_access_token, user: user, scopes: [:api]) }

  def request_token
    get api('/unfurl_access_token', user, personal_access_token: api_token)
  end

  def stored
    OC::Authn::UnfurlGitToken.find_by(user: user)
  end

  it 'creates and stores a repository-scoped token without notifying the user' do
    api_token

    expect(Notify).not_to receive(:access_token_created_email)

    expect { request_token }.to change { user.personal_access_tokens.count }.by(1)

    expect(response).to have_gitlab_http_status(:ok)

    created = user.personal_access_tokens.find(json_response['id'])
    expect(created).to have_attributes(
      name: OC::GIT_TOKEN_NAME,
      scopes: OC::Authn::UnfurlGitTokenService::TOKEN_SCOPES,
      expire_notification_delivered: true,
      after_expiry_notification_delivered: true
    )
    expect(stored).to have_attributes(personal_access_token_id: created.id, token: json_response['token'])
    expect(user.custom_attributes).to be_empty
  end

  it 'hands back the stored token while it is still live' do
    request_token
    first = json_response

    expect { request_token }.not_to change { user.personal_access_tokens.count }
    expect(json_response).to eq(first)
  end

  it 'replaces an expired token, and the token it replaces' do
    request_token
    expired = user.personal_access_tokens.find(json_response['id'])
    expired.update_column(:expires_at, 1.day.ago)

    request_token

    expect(json_response['id']).not_to eq(expired.id)
    expect(PersonalAccessToken.exists?(expired.id)).to be(false)
    expect(stored).to have_attributes(personal_access_token_id: json_response['id'], token: json_response['token'])
  end

  it 'answers with the reason a token could not be made' do
    allow_next_instance_of(OC::Authn::UnfurlGitTokenService) do |service|
      allow(service).to receive(:execute).and_return(ServiceResponse.error(message: 'nope', reason: :not_a_status))
    end

    request_token

    expect(response).to have_gitlab_http_status(:unprocessable_entity)
    expect(json_response['message']).to eq('nope')
  end

  it 'does not expose a token to an unauthenticated request' do
    expect { get api('/unfurl_access_token') }.not_to change { PersonalAccessToken.count }

    expect(response).to have_gitlab_http_status(:unauthorized)
  end
end
