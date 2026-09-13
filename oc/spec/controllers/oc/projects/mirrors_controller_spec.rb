# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Projects::MirrorsController, feature_category: :source_code_management do
  let_it_be_with_reload(:project) do
    create(:project, :repository, import_type: 'github', import_url: 'https://github.example.test/team/source.git')
  end

  let(:repository) { instance_double(Repository, empty?: false, root_ref: project.default_branch) }
  let(:route_params) { { namespace_id: project.namespace.to_param, project_id: project.to_param } }

  before do
    project.record_unfurl_type!(OC::REGULAR_PROJECT)
    project.build_or_assign_import_data(data: { is_mirror: true, mirror_enabled: true })
    project.import_data.save!
    sign_in(project.first_owner)
  end

  # The controller acts on whichever Project it loads, not the one built here.
  def stub_loaded_project
    allow_next_found_instance_of(Project) do |loaded|
      allow(loaded).to receive_messages(ensure_repository: nil, repository: repository)
    end
  end

  describe '#update' do
    it 'persists the continuous-mirroring setting submitted by the settings checkbox' do
      put :update, params: route_params.merge(project: { 'mirror_enabled?' => '0' })

      expect(response).to redirect_to(project_settings_repository_path(project, anchor: 'js-push-remote-settings'))
      expect(project.reload.import_data.data['mirror_enabled']).to be(false)
    end

    it 'leaves a project that is not a pull mirror to the push-mirror controller' do
      project.build_or_assign_import_data(data: { is_mirror: false })
      project.import_data.save!

      put :update, params: route_params.merge(project: { remote_mirrors_attributes: { id: '1' } })

      expect(flash[:alert]).to eq('Invalid mirror update request')
    end
  end

  describe '#update_now' do
    it 'fetches the source and queues a push pipeline when its HEAD changes' do
      stub_loaded_project
      allow(repository).to receive(:commit).and_return(
        instance_double(Commit, id: 'old-upstream-sha'), instance_double(Commit, id: 'new-upstream-sha')
      )
      expect(repository).to receive(:fetch_as_mirror).with(project.unsafe_import_url, forced: true)
      expect(CreatePipelineWorker).to receive(:perform_async)
        .with(project.id, project.owner.id, project.default_branch_or_main, :push)

      post :update_now, params: route_params

      expect(response).to redirect_to(project_settings_repository_path(project, anchor: 'js-push-remote-settings'))
      expect(flash[:notice]).to eq('Repository updated successfully.')
    end

    it 'does not queue a duplicate pipeline when the source HEAD is unchanged' do
      stub_loaded_project
      allow(repository).to receive(:commit).and_return(instance_double(Commit, id: 'unchanged-upstream-sha'))
      expect(repository).to receive(:fetch_as_mirror).with(project.unsafe_import_url, forced: true)
      expect(CreatePipelineWorker).not_to receive(:perform_async)

      post :update_now, params: route_params

      expect(response).to redirect_to(project_settings_repository_path(project, anchor: 'js-push-remote-settings'))
      expect(flash[:notice]).to eq('Repository updated successfully.')
    end
  end
end
