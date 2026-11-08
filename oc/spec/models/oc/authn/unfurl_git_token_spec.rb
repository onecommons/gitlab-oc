# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Authn::UnfurlGitToken, feature_category: :system_access do
  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:personal_access_token) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:token) }
  end

  it 'reads the token back' do
    stored = create(:oc_unfurl_git_token)

    expect(described_class.find(stored.id).token).to eq(stored.personal_access_token.token)
  end

  # The point of the table: a dump or a raw read holds ciphertext only.
  it 'never stores the token itself' do
    stored = create(:oc_unfurl_git_token)
    raw = described_class.connection.select_value(
      "SELECT token::text FROM oc_unfurl_git_tokens WHERE id = #{stored.id.to_i}")

    expect(raw).to be_present
    expect(raw).not_to include(stored.token)
  end

  it 'is deleted with its user' do
    stored = create(:oc_unfurl_git_token)

    expect { stored.user.delete }.to change { described_class.count }.by(-1)
  end
end
