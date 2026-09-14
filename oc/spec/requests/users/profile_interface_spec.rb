# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'A profile page interface indicator', feature_category: :user_profile do
  # Refound per example: one of them flips `external` on this very object.
  let_it_be_with_refind(:viewer) { create(:user, :with_namespace) }

  def visit_profile(user)
    get user_path(user)
    response.body
  end

  before do
    sign_in(viewer)
  end

  it 'names the interface a deploying user chose, and offers to change it' do
    viewer.update!(external: true)

    body = visit_profile(viewer)

    expect(body).to include('Deploy applications')
    expect(body).to include(user_settings_profile_path)
  end

  it 'names the developing interface' do
    expect(visit_profile(viewer)).to include('Develop applications')
  end

  it 'does not offer to change someone else\'s' do
    other = create(:user, :with_namespace)

    body = visit_profile(other)

    expect(body).to include('Develop applications')
    expect(body).not_to include(">Change<")
  end
end
