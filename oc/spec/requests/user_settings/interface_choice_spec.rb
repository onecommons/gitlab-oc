# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'The interface choice in a profile', feature_category: :user_profile do
  let(:user) { create(:user) }

  before do
    # The Vue rewrite of this page is default-off in production but on in
    # specs, and it has no slot; when it ships the choice has to move into it.
    stub_feature_flags(edit_user_profile_vue: false)
    sign_in(user)
  end

  it 'is offered on the profile page' do
    get user_settings_profile_path

    expect(response.body).to include('user_oc_interface')
  end

  it 'switches a user to the simple interface and back' do
    patch user_settings_profile_path, params: { user: { oc_interface: 'deploy' } }
    expect(user.reload).to be_external

    patch user_settings_profile_path, params: { user: { oc_interface: 'develop' } }
    expect(user.reload).not_to be_external
  end

  it 'leaves the flag alone when the choice is not submitted' do
    user.update!(external: true)

    patch user_settings_profile_path, params: { user: { bio: 'hello' } }

    expect(user.reload).to be_external
  end
end
