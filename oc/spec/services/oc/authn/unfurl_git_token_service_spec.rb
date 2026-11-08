# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Authn::UnfurlGitTokenService, feature_category: :system_access do
  include ExclusiveLeaseHelpers

  let_it_be(:user) { create(:user) }

  subject(:service) { described_class.for_user(user, organization_id: user.organization_id) }

  def stored
    OC::Authn::UnfurlGitToken.find_by(user: user)
  end

  it 'mints a repository token, stores it encrypted, and hands it back' do
    response = service.execute

    expect(response).to be_success
    token = PersonalAccessToken.find(response[:id])
    expect(token).to have_attributes(user: user, name: OC::GIT_TOKEN_NAME, scopes: described_class::TOKEN_SCOPES,
      expire_notification_delivered: true, after_expiry_notification_delivered: true)
    expect(response.payload).to include(token: stored.token, username: user.username)
    expect(stored.personal_access_token).to eq(token)
  end

  it 'reuses the stored token while it is active' do
    first = service.execute

    expect { described_class.for_user(user, organization_id: user.organization_id).execute }
      .not_to change { PersonalAccessToken.count }
    expect(stored.personal_access_token_id).to eq(first[:id])
  end

  it 'replaces an inactive token and deletes it' do
    old = PersonalAccessToken.find(service.execute[:id])
    old.update_column(:expires_at, 1.day.ago)

    response = described_class.for_user(user, organization_id: user.organization_id).execute

    expect(response[:id]).not_to eq(old.id)
    expect(PersonalAccessToken.exists?(old.id)).to be(false)
    expect(OC::Authn::UnfurlGitToken.where(user: user).count).to eq(1)
  end

  # Two page loads at once must not both mint: the second waits for the first.
  it 'does not mint while another request holds the lock for this user' do
    stub_exclusive_lease_taken("oc:unfurl_git_token:user:#{user.id}", timeout: 30.seconds)

    expect { expect(service.execute).to be_error }.not_to change { PersonalAccessToken.count }
  end

  it 'returns the error when the token cannot be created' do
    allow_next_instance_of(PersonalAccessTokens::CreateService) do |create|
      allow(create).to receive(:execute).and_return(ServiceResponse.error(message: 'nope'))
    end

    expect(service.execute).to have_attributes(status: :error, message: 'nope')
    expect(stored).to be_nil
  end
end
