# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'The sitemap', feature_category: :groups_and_projects do
  let(:blueprints) { create(:group, path: 'blueprints', parent: create(:group, path: 'onecommons')) }
  let(:verified) { create(:project, :public, :repository, group: blueprints) }
  let(:elsewhere) { create(:project, :public, :repository) }

  before do
    [verified, elsewhere].each do |project|
      project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_BLUEPRINT)
    end
  end

  it 'lists the verified blueprints and the fork\'s public pages' do
    get '/sitemap.xml'

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include(verified.full_path)
    expect(response.body).not_to include(elsewhere.full_path)
    expect(response.body).to include('/explore/blueprints')
    expect(response.body).to include('/cloud')
  end
end
