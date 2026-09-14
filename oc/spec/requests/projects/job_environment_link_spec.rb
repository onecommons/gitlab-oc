# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'A job page environment link', feature_category: :continuous_delivery do
  let_it_be(:user) { create(:user, :with_namespace) }
  let_it_be(:project) { create(:project, :repository, namespace: user.namespace) }
  let_it_be(:pipeline) { create(:ci_pipeline, project: project) }

  let_it_be(:build) do
    create(:ci_build, :with_deployment, environment: 'production', project: project, pipeline: pipeline)
  end

  before do
    sign_in(user)
  end

  def environment_link
    get project_job_path(project, build, format: :json)

    json_response.dig('deployment_status', 'environment', 'environment_path')
  end

  it 'carries the environment name on a dashboard, which the app routes by' do
    project.record_unfurl_type!(OC::UNFURL_DASHBOARD)

    expect(environment_link).to end_with('/-/environments/production')
  end

  it 'carries the id on an ordinary project' do
    project.record_unfurl_type!(OC::REGULAR_PROJECT)

    expect(environment_link).to end_with("/-/environments/#{build.deployment.environment.id}")
  end
end
