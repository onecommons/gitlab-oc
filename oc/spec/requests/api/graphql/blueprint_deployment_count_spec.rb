# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Project.blueprintDeploymentCount', feature_category: :continuous_delivery do
  include GraphqlHelpers

  let_it_be(:user) { create(:user) }
  let_it_be(:blueprint) { create(:project, :public) }
  let_it_be(:other_blueprint) { create(:project, :public) }
  let_it_be(:deployer) { create(:project, :public) }

  def record(blueprint_project, at)
    OC::Environments::BlueprintDeployment.create!(blueprint_project: blueprint_project,
      deployed_project: deployer, finished_at: at)
  end

  def counts_for(*projects)
    query = <<~GQL
      {
        #{projects.each_with_index.map { |p, i| "p#{i}: project(fullPath: \"#{p.full_path}\") { blueprintDeploymentCount }" }.join("\n")}
      }
    GQL

    post_graphql(query, current_user: user)
    projects.each_with_index.map { |_, i| graphql_data.dig("p#{i}", 'blueprintDeploymentCount') }
  end

  it 'is zero for a project nothing was deployed from' do
    expect(counts_for(blueprint)).to eq([0])
  end

  it 'counts only the deployments of that blueprint' do
    record(blueprint, 1.hour.ago)
    record(blueprint, 2.hours.ago)
    record(other_blueprint, 3.hours.ago)

    expect(counts_for(blueprint, other_blueprint)).to eq([2, 1])
  end

  it 'resolves a page of blueprints with one count query, not one per project' do
    record(blueprint, 1.hour.ago)
    record(other_blueprint, 2.hours.ago)

    recorder = ActiveRecord::QueryRecorder.new do
      counts_for(blueprint, other_blueprint, deployer)
    end

    counting = recorder.log.count { |query| query.include?('oc_blueprint_deployments') }

    expect(counting).to eq(1)
  end
end
