# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EnvironmentEntity, feature_category: :continuous_delivery do
  let(:user) { build_stubbed(:user) }
  let(:project) { build_stubbed(:project) }
  let(:request) do
    double('request', current_user: user, project: project) # rubocop: disable RSpec/VerifiedDoubles -- a duck, as in the upstream spec
  end

  def path_for(name, oc_dashboard_link: true)
    environment = build_stubbed(:environment, project: project, name: name)

    described_class.new(environment, request: request, oc_dashboard_link: oc_dashboard_link)
      .as_json[:environment_path]
  end

  context 'when the project is a dashboard' do
    before do
      allow(project).to receive(:recorded_unfurl_type).and_return(OC::UNFURL_DASHBOARD)
    end

    it 'links the environment by name, which is what the dashboard app resolves' do
      expect(path_for('production')).to end_with('/-/environments/production')
    end

    it 'keeps the id for a name the route segment would not carry' do
      allow(project).to receive(:recorded_unfurl_type).and_return(OC::UNFURL_DASHBOARD)

      expect(path_for('review/my-branch')).to match(%r{/-/environments/\d+\z})
    end
  end

  it 'leaves an ordinary project linking by id' do
    allow(project).to receive(:recorded_unfurl_type).and_return(OC::REGULAR_PROJECT)

    expect(path_for('production')).to match(%r{/-/environments/\d+\z})
  end

  # The environments index serializes a page at a time, so it must not pay a
  # classification read per row.
  it 'does not look at the project unless the caller asked for a dashboard link' do
    expect(project).not_to receive(:recorded_unfurl_type)

    expect(path_for('production', oc_dashboard_link: false)).to match(%r{/-/environments/\d+\z})
  end
end
