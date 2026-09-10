# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PersonalAccessToken, feature_category: :system_access do
  let_it_be(:user) { create(:user) }

  it 'requires an expiry, as upstream does' do
    token = described_class.new(user: user, name: 'ordinary', scopes: [:api])

    expect(token).not_to be_valid
    expect(token.errors[:expires_at]).to be_present
  end

  # Nothing renews the deployment token, so an expiry is an outage with a date.
  it 'lets the Unfurl deployment token go without one' do
    token = described_class.new(user: user, name: ::OC::PROJECT_TOKEN_NAME, scopes: [:api])

    expect(token).to be_valid
    expect(token.expires_at).to be_nil
  end
end
