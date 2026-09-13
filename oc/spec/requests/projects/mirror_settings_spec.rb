# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'A pull mirror on the project pages', feature_category: :source_code_management do
  let_it_be(:user) { create(:user, :with_namespace) }
  let_it_be_with_reload(:project) do
    create(:project, :repository, namespace: user.namespace,
      import_type: 'github', import_url: 'https://github.example.test/team/source.git')
  end

  before do
    project.record_unfurl_type!(OC::REGULAR_PROJECT)
    sign_in(user)
  end

  def mirror!(enabled: true)
    project.build_or_assign_import_data(data: { is_mirror: true, mirror_enabled: enabled })
    project.import_data.save!
  end

  context 'when the project is a pull mirror' do
    before do
      mirror!
    end

    it 'replaces the push-mirror settings with the fork section' do
      get project_settings_repository_path(project)

      expect(response).to have_gitlab_http_status(:ok)
      expect(response.body).to include('This repository is configured as a mirror of')
      expect(response.body).to include('Enable continuous mirroring')
      expect(response.body).not_to include('Mirrored repositories')
    end

    it 'does not leak import credentials into the banner or the settings section' do
      project.update!(import_url: 'https://someone:sekrit-token@github.example.test/team/source.git')
      mirror!

      get project_path(project)
      expect(response.body).to include('https://github.example.test/team/source')
      expect(response.body).not_to include('sekrit-token')

      get project_settings_repository_path(project)
      expect(response.body).not_to include('sekrit-token')
    end

    it 'names the source on the project overview and the repository tree' do
      get project_path(project)
      expect(response.body).to include('This repository is a mirror of')

      get project_tree_path(project, project.default_branch)
      expect(response.body).to include('This repository is a mirror of')
    end
  end

  context 'when the project is not a mirror' do
    it 'leaves both pages as upstream renders them' do
      get project_settings_repository_path(project)
      expect(response.body).to include('Mirrored repositories')
      expect(response.body).not_to include('Enable continuous mirroring')

      get project_path(project)
      expect(response.body).not_to include('This repository is a mirror of')
    end
  end
end
