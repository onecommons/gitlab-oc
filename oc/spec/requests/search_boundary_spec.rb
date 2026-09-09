# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Global search', feature_category: :global_search do
  it 'is not offered to a simple-interface user' do
    sign_in(create(:user, :external))

    get search_path, params: { search: 'blueprint' }

    expect(response).to have_gitlab_http_status(:not_found)
  end

  it 'is offered to everyone else' do
    sign_in(create(:user))

    get search_path, params: { search: 'blueprint' }

    expect(response).to have_gitlab_http_status(:ok)
  end
end
