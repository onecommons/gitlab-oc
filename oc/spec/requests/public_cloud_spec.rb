# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'The public cloud page', feature_category: :groups_and_projects do
  it 'renders anonymously with the cloudmap the package expects' do
    create(:ci_instance_variable, key: 'UNFURL_CLOUDMAP_JSON', value: '{"a":1}')

    get '/cloud'

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('public-cloud-layout')
    expect(response.body).to include('{&quot;a&quot;:1}')
  end
end
