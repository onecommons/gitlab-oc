# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'The deploy badge', feature_category: :continuous_delivery do
  let_it_be(:blueprint) { create(:project, :public) }
  let_it_be(:private_project) { create(:project, :private) }
  let_it_be(:deployer) { create(:project) }

  def badge_path(project, format: :svg, **params)
    project_deploy_badge_path(project, format: format, **params)
  end

  before_all do
    2.times do |n|
      OC::Environments::BlueprintDeployment.create!(blueprint_project: blueprint,
        deployed_project: deployer, finished_at: n.hours.ago)
    end
  end

  it 'renders an SVG to an anonymous visitor, with the deploy count' do
    get badge_path(blueprint, count: true)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.media_type).to eq('image/svg+xml')
    expect(response.body).to include('<svg', '2')
  end

  it 'renders an HTML document for an iframe' do
    get badge_path(blueprint, format: :html)

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('Deploy with', 'Unfurl Cloud')
  end

  it 'renders each badge style' do
    %w[default white monochrome mono_inverse].each do |type|
      get badge_path(blueprint, type: type, cloud: true, count: true)

      expect(response).to have_gitlab_http_status(:ok), "#{type} did not render"
      expect(response.body).to include('<svg')
    end
  end

  # The type names a template directory, so anything outside the four renders
  # the default rather than whatever the caller asked for. A traversal attempt
  # never even arrives -- upstream's middleware answers that with a 400.
  it 'falls back to the default style for an unknown type' do
    get badge_path(blueprint, type: 'neon')

    expect(response).to have_gitlab_http_status(:ok)
    expect(response.body).to include('<svg')
  end

  it 'does not answer for a private project, even to a member' do
    sign_in(private_project.first_owner)

    get badge_path(private_project)

    expect(response).to have_gitlab_http_status(:not_found)
  end

  # The route constraint declines before the action runs, so this is a
  # redirect rather than the action's own 404. Either way, no badge.
  it 'does not render a badge for a project that does not exist' do
    get "/#{blueprint.namespace.full_path}/no-such-project/-/deploybutton.svg"

    expect(response).not_to have_gitlab_http_status(:ok)
    expect(response.body).not_to include('<svg')
  end
end
