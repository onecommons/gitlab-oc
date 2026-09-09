# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProjectPolicy, feature_category: :continuous_delivery do
  let_it_be(:member) { create(:user, :with_namespace) }

  let(:current_user) { nil }
  let(:visibility) { :public }
  let(:unfurl_type) { OC::UNFURL_DASHBOARD }
  let(:project) do
    create(:project, visibility).tap do |project|
      project.project_feature.update!(builds_access_level: ProjectFeature::DISABLED)
      project.record_unfurl_type!(unfurl_type)
    end
  end

  subject { described_class.new(current_user, project) }

  context 'when the project is a dashboard' do
    it 'lets anyone who can see a public dashboard read its deployments' do
      expect_allowed(:read_environment, :read_deployment)
    end

    it 'grants no write ability along with the read' do
      expect_disallowed(:create_deployment, :update_environment)
    end

    # The boundary opens up what builds_disabled closes. Switching environments
    # off is a separate, deliberate act, and upstream's gate for it stands.
    it 'does not override environments being switched off' do
      project.project_feature.update!(environments_access_level: ProjectFeature::DISABLED)

      expect_disallowed(:read_environment, :read_deployment)
    end

    context 'when it is private' do
      let(:visibility) { :private }

      it 'stays private to an anonymous reader' do
        expect_disallowed(:read_environment, :read_deployment)
      end

      context 'when the reader is a member' do
        let(:current_user) { member }

        before do
          project.add_guest(member)
        end

        it 'reads as it would if it were public' do
          expect_allowed(:read_environment, :read_deployment)
        end
      end
    end
  end

  context 'when the project is a regular one' do
    let(:unfurl_type) { OC::REGULAR_PROJECT }

    it 'keeps upstream boundary, which builds_disabled closes' do
      expect_disallowed(:read_environment, :read_deployment)
    end
  end

  context 'when the classifier has not seen the project' do
    let(:project) do
      create(:project, :public).tap do |project|
        project.project_feature.update!(builds_access_level: ProjectFeature::DISABLED)
      end
    end

    it 'is treated as a regular project' do
      expect_disallowed(:read_environment, :read_deployment)
    end
  end
end
