# frozen_string_literal: true

require 'spec_helper'

require_migration!

RSpec.describe RevokeOCPlaintextUnfurlGitTokens, migration: :gitlab_main, feature_category: :system_access do
  let(:organizations) { table(:organizations) }
  let(:users) { table(:users) }
  let(:tokens) { table(:personal_access_tokens) }
  let(:attributes) { table(:user_custom_attributes) }

  let(:organization) { organizations.create!(name: 'oc', path: 'oc') }

  def user(name)
    users.create!(username: name, email: "#{name}@example.com", projects_limit: 10, organization_id: organization.id)
  end

  def token(owner, name: 'UNFURL_GIT_ACCESS')
    tokens.create!(user_id: owner.id, name: name, organization_id: organization.id, expires_at: 7.days.from_now)
  end

  def remember(owner, id)
    attributes.create!(user_id: owner.id, key: 'unfurl_git_token', value: "#{id}|glpat-secret")
  end

  it 'revokes the tokens the attributes named, and deletes the attributes' do
    alice = user('alice')
    stored = token(alice)
    remember(alice, stored.id)
    other = attributes.create!(user_id: alice.id, key: 'something_else', value: 'kept')

    migrate!

    expect(stored.reload.revoked).to be(true)
    expect(attributes.where(key: 'unfurl_git_token')).to be_empty
    expect(attributes.find(other.id).value).to eq('kept')
  end

  it "never revokes a token of another user, or one this endpoint did not make" do
    alice = user('alice')
    bob = user('bob')
    bobs = token(bob)
    alices_other = token(alice, name: 'my own token')
    remember(alice, bobs.id)
    attributes.create!(user_id: bob.id, key: 'unfurl_git_token', value: "#{alices_other.id}|glpat-secret")

    migrate!

    expect(bobs.reload.revoked).to be(false)
    expect(alices_other.reload.revoked).to be(false)
    expect(attributes.where(key: 'unfurl_git_token')).to be_empty
  end

  it 'deletes a value it cannot read' do
    alice = user('alice')
    attributes.create!(user_id: alice.id, key: 'unfurl_git_token', value: 'garbage')

    expect { migrate! }.not_to raise_error
    expect(attributes.count).to eq(0)
  end
end
