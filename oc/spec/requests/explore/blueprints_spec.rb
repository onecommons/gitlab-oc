# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Blueprint discovery', feature_category: :groups_and_projects do
  it 'mounts the app and declares its canonical URL' do
    get '/explore/blueprints'

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('js-oc-explore-blueprints')
    expect(response.headers['Link']).to eq(%(<#{Gitlab.config.gitlab.url}/explore/blueprints>; rel="canonical"))
  end

  it 'serves each tab from the same action, so a reload keeps the tab' do
    get '/explore/blueprints/all'

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('js-oc-explore-blueprints')
  end

  it 'leads Explore with blueprints' do
    get '/explore'

    expect(response).to redirect_to('/explore/blueprints')
  end
end
