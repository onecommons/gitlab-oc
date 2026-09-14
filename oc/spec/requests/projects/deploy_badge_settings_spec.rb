# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'The deploy badge settings', feature_category: :continuous_delivery do
  let_it_be(:user) { create(:user) }
  let_it_be(:blueprint) { create(:project) }
  let_it_be(:regular_project) { create(:project) }

  before_all do
    blueprint.record_unfurl_type!(OC::UNFURL_BLUEPRINT)
    blueprint.add_maintainer(user)
    regular_project.record_unfurl_type!(OC::REGULAR_PROJECT)
    regular_project.add_maintainer(user)
  end

  before do
    sign_in(user)
  end

  it 'offers the deploy button on a blueprint, with the direct and embeddable links' do
    get edit_project_path(blueprint)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('Unfurl Deploy Button')
    expect(response.body).to include('id="unfurl-badge-settings"')
    expect(response.body).to include("/#{blueprint.full_path}/-/deploybutton.svg")
    # The embeddable snippet is an <a><img> pair carried in a value attribute,
    # so its quotes arrive escaped. The host is the request's, not the
    # configured one, so this pins the shape rather than the origin.
    expect(response.body).to include("#{blueprint.full_path}&quot;&gt;&lt;img").or include(
      "#{blueprint.full_path}&quot;><img")
  end

  # Only a blueprint is deployed from, so only a blueprint gets the button --
  # and upstream's own Badges section stays either way.
  it 'does not offer it on a project that is not a blueprint' do
    get edit_project_path(regular_project)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).not_to include('id="unfurl-badge-settings"')
    expect(response.body).to include('Badges')
  end
end
