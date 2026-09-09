# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProjectFeature, feature_category: :continuous_integration do
  describe '.required_minimum_access_level' do
    # CI holds the deployment credentials, so reading it is a maintainer's business.
    it 'asks for maintainer on builds, where upstream asks for guest' do
      expect(described_class.required_minimum_access_level(:builds)).to eq(Gitlab::Access::MAINTAINER)
    end

    it 'leaves the features upstream sets alone' do
      expect(described_class.required_minimum_access_level(:environments)).to eq(Gitlab::Access::REPORTER)
      expect(described_class.required_minimum_access_level(:merge_requests)).to eq(Gitlab::Access::REPORTER)
    end
  end

  describe '#feature_available?' do
    let_it_be(:developer) { create(:user, :with_namespace) }
    let_it_be(:maintainer) { create(:user, :with_namespace) }
    let_it_be(:project, refind: true) do
      create(:project, :public).tap do |project|
        project.add_developer(developer)
        project.add_maintainer(maintainer)
        project.project_feature.update!(builds_access_level: ProjectFeature::PRIVATE)
      end
    end

    it 'keeps a developer out of private CI' do
      expect(project.feature_available?(:builds, developer)).to be(false)
    end

    it 'lets a maintainer in' do
      expect(project.feature_available?(:builds, maintainer)).to be(true)
    end

    it 'leaves another private feature at the level upstream set' do
      project.project_feature.update!(environments_access_level: ProjectFeature::PRIVATE)

      expect(project.feature_available?(:environments, developer)).to be(true)
    end
  end
end
