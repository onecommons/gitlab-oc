# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Project, feature_category: :groups_and_projects do
  describe '#refresh_unfurl_type!' do
    let(:project) { create(:project) }
    let(:repository) do
      instance_double(Repository, ensemble_template_yaml: ensemble_template_yaml, unfurl_yaml: unfurl_yaml)
    end

    before do
      allow(project).to receive(:repository).and_return(repository)
    end

    shared_examples 'an Unfurl project type' do |type, predicate|
      it "classifies the project as #{type}" do
        project.refresh_unfurl_type!

        expect(project.custom_attributes.find_by(key: 'unfurl_type').value).to eq(type)
        expect(project.public_send(predicate)).to be(true)
      end
    end

    context 'when the repository contains an ensemble template' do
      let(:ensemble_template_yaml) { 'apiVersion: unfurl/v1alpha1' }
      let(:unfurl_yaml) { nil }

      include_examples 'an Unfurl project type', OC::UNFURL_BLUEPRINT, :unfurl_blueprint?
    end

    context 'when the repository contains an Unfurl dashboard file but no ensemble template' do
      let(:ensemble_template_yaml) { nil }
      let(:unfurl_yaml) { 'apiVersion: unfurl/v1alpha1' }

      include_examples 'an Unfurl project type', OC::UNFURL_DASHBOARD, :unfurl_dashboard?
    end

    context 'when the repository has neither Unfurl metadata file' do
      let(:ensemble_template_yaml) { nil }
      let(:unfurl_yaml) { nil }

      include_examples 'an Unfurl project type', OC::REGULAR_PROJECT, :regular_project?
    end
  end

  describe '#unfurl_type_without_recording' do
    let(:project) { create(:project) }

    context 'when the classifier has already recorded a type' do
      before do
        project.record_unfurl_type!(OC::UNFURL_DASHBOARD)
      end

      it 'answers from the record without touching the repository' do
        expect(project).not_to receive(:repository)

        expect(project.unfurl_type_without_recording).to eq(OC::UNFURL_DASHBOARD)
      end
    end

    context 'when nothing has classified the project yet' do
      let(:repository) do
        instance_double(Repository, ensemble_template_yaml: nil, unfurl_yaml: 'apiVersion: unfurl/v1alpha1')
      end

      before do
        allow(project).to receive_messages(repository: repository, repository_exists?: true)
      end

      it 'answers from the repository' do
        expect(project.unfurl_type_without_recording).to eq(OC::UNFURL_DASHBOARD)
      end

      it 'records nothing, because callers are rendering a GET' do
        project.unfurl_type_without_recording

        expect(project.reset.recorded_unfurl_type).to be_nil
      end
    end

    context 'when the project has no repository' do
      before do
        allow(project).to receive(:repository_exists?).and_return(false)
      end

      it 'is nil rather than raising' do
        expect(project.unfurl_type_without_recording).to be_nil
      end
    end
  end

  describe '#work_items_sync_enabled?' do
    let(:project) { create(:project) }

    def set_unfurl_type(value)
      project.custom_attributes.create!(key: 'unfurl_type', value: value)
    end

    it 'is enabled for unfurl blueprints' do
      set_unfurl_type(OC::UNFURL_BLUEPRINT)

      expect(project.work_items_sync_enabled?).to be(true)
    end

    it 'is enabled for unfurl dashboards' do
      set_unfurl_type(OC::UNFURL_DASHBOARD)

      expect(project.work_items_sync_enabled?).to be(true)
    end

    it 'is disabled for regular projects by default' do
      set_unfurl_type(OC::REGULAR_PROJECT)

      expect(project.work_items_sync_enabled?).to be(false)
      expect(project.work_items_sync_opted_in?).to be(false)
    end

    it 'can be opted in and out for regular projects' do
      set_unfurl_type(OC::REGULAR_PROJECT)

      project.enable_work_items_sync!(true)
      expect(project.work_items_sync_opted_in?).to be(true)
      expect(project.work_items_sync_enabled?).to be(true)

      project.enable_work_items_sync!(false)
      expect(project.work_items_sync_enabled?).to be(false)
    end

    it 'lets an unfurl project turn it off, overriding the default' do
      set_unfurl_type(OC::UNFURL_DASHBOARD)
      expect(project.work_items_sync_on_by_default?).to be(true)
      expect(project.work_items_sync_enabled?).to be(true)

      project.enable_work_items_sync!(false)

      expect(project.work_items_sync_enabled?).to be(false)
      # still on by default -- the explicit choice is what turned it off
      expect(project.work_items_sync_on_by_default?).to be(true)
    end

    it 'touches the project so the reconcile job sees the change' do
      set_unfurl_type(OC::REGULAR_PROJECT)
      project.update_column(:updated_at, 2.days.ago)

      expect { project.enable_work_items_sync!(true) }
        .to change { project.reload.updated_at }
    end
  end

  describe '#sync_confidential_work_items?' do
    let_it_be_with_reload(:project) { create(:project, :private) }

    it 'is off by default, even on a private project' do
      expect(project.sync_confidential_work_items?).to be(false)
      expect(project.work_items_sync_confidential_included?).to be(false)
    end

    it 'can be opted into, and back out of, on a private project' do
      project.include_work_items_sync_confidential!(true)

      expect(project.work_items_sync_confidential_included?).to be(true)
      expect(project.sync_confidential_work_items?).to be(true)

      project.include_work_items_sync_confidential!(false)

      expect(project.sync_confidential_work_items?).to be(false)
    end

    it 'cannot be opted into on public or internal projects' do
      [:public, :internal].each do |visibility|
        other = create(:project, visibility)
        other.include_work_items_sync_confidential!(true)

        expect(other.sync_confidential_work_items?).to be(false)
      end
    end
  end

  describe 'pull mirroring' do
    let_it_be_with_reload(:project) do
      create(:project, import_type: 'github', import_url: 'https://github.example.test/team/source.git')
    end

    def flag_as_mirror(is_mirror: true, mirror_enabled: true)
      project.build_or_assign_import_data(data: { is_mirror: is_mirror, mirror_enabled: mirror_enabled })
      project.import_data.save!
    end

    before do
      project.record_unfurl_type!(OC::REGULAR_PROJECT)
    end

    describe '#mirror?' do
      it 'is true once the import has recorded the request to mirror' do
        expect(project.mirror?).to be_falsey

        flag_as_mirror

        expect(project.mirror?).to be(true)
      end

      it 'does not classify the project, because the banner asks this on a GET' do
        project.custom_attributes.find_by(key: 'unfurl_type').destroy!
        flag_as_mirror

        expect { expect(project.mirror?).to be_falsey }
          .not_to change { project.custom_attributes.count }
      end

      it 'is false for a dashboard, which is imported from a template rather than mirrored' do
        flag_as_mirror
        project.record_unfurl_type!(OC::UNFURL_DASHBOARD)

        expect(project.mirror?).to be_falsey
      end
    end

    describe '#mirror_enabled?' do
      it 'follows the setting the repository settings page writes' do
        flag_as_mirror(mirror_enabled: false)

        expect(project.mirror?).to be(true)
        expect(project.mirror_enabled?).to be_falsey

        flag_as_mirror

        expect(project.mirror_enabled?).to be(true)
      end
    end

    describe '#remove_import_data' do
      it 'keeps the credentials a mirror needs to go on fetching' do
        flag_as_mirror

        expect { project.remove_import_data }.not_to change { ProjectImportData.count }
      end

      it 'removes them from a project that is not a regular project' do
        flag_as_mirror
        project.record_unfurl_type!(OC::UNFURL_BLUEPRINT)

        expect { project.remove_import_data }.to change { ProjectImportData.count }.by(-1)
      end
    end
  end
end
