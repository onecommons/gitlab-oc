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

  describe '.for_project_bot' do
    let_it_be(:project) { create(:project) }

    subject(:bot_service) { described_class.for_project_bot(project) }

    def bot_token
      OC::Authn::UnfurlGitToken.find_by(user_id: project.bots.pluck(:id))&.personal_access_token
    end

    it 'creates a project bot that can push, with a write-only token' do
      response = bot_service.execute

      expect(response).to be_success
      token = PersonalAccessToken.find(response[:id])
      expect(token.user).to be_project_bot
      expect(token).to have_attributes(name: OC::CLOUDMAP_PUSH_TOKEN_NAME, scopes: %w[write_repository],
        expire_notification_delivered: true)
      expect(project.team.max_member_access(token.user_id)).to eq(Gitlab::Access::MAINTAINER)
      expect(response[:username]).to eq(token.user.username)
    end

    it 'reuses the token until a day before it expires' do
      first = bot_service.execute

      expect { described_class.for_project_bot(project).execute }.not_to change { PersonalAccessToken.count }
      expect(bot_token.id).to eq(first[:id])
    end

    it 'rotates it within a day of expiry, keeping the bot' do
      first = PersonalAccessToken.find(bot_service.execute[:id])
      first.update_column(:expires_at, Date.tomorrow)

      expect(Notify).not_to receive(:access_token_rotated_email)
      response = described_class.for_project_bot(project).execute

      expect(response[:id]).not_to eq(first.id)
      expect(first.reload).to be_revoked
      expect(bot_token.user).to eq(first.user)
    end

    it 'reuses a token with no expiry' do
      first = PersonalAccessToken.find(bot_service.execute[:id])
      first.update_column(:expires_at, nil)

      expect(described_class.for_project_bot(project).execute[:id]).to eq(first.id)
    end

    it 'makes a new bot when the token was revoked' do
      first = PersonalAccessToken.find(bot_service.execute[:id])
      first.revoke!

      response = described_class.for_project_bot(project).execute

      expect(PersonalAccessToken.find(response[:id]).user).not_to eq(first.user)
      expect(OC::Authn::UnfurlGitToken.where(user_id: first.user_id)).to be_empty
    end

    it 'never takes another bot of the project for its own' do
      other_bot = create(:user, :project_bot)
      project.add_maintainer(other_bot)
      create(:personal_access_token, user: other_bot)

      response = bot_service.execute

      expect(PersonalAccessToken.find(response[:id]).user).not_to eq(other_bot)
    end
  end
end
