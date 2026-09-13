# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Import::GithubService, feature_category: :importers do
  let_it_be(:user) { create(:user) }
  let_it_be_with_reload(:project) do
    create(:project, import_type: 'github', import_url: 'https://github.example.test/team/source.git')
  end

  let(:octokit) { instance_double(Octokit::Client) }
  let(:client) { instance_double(Gitlab::GithubImport::Client, octokit: octokit) }
  let(:repo) { { id: 42, full_name: 'team/source' } }
  let(:params) { {} }
  let(:service) { described_class.new(client, user, params) }

  before do
    allow(service).to receive_messages(
      rate_limited?: false, validate_context: nil, validate_access_token: nil,
      track_access_level: nil, store_import_settings: nil, create_project: project, repo: repo
    )
    allow(client).to receive(:repository).with('team/source').and_return(repo)
    allow(octokit).to receive(:hooks).with(42).and_return([])
  end

  it 'records the project as a mirror and registers the push webhook' do
    expect(octokit).to receive(:create_hook)

    result = service.execute({}, :github)

    expect(result[:status]).to eq(:success)

    import_data = project.reload.import_data
    expect(import_data.data).to include(
      'is_mirror' => true, 'mirror_enabled' => true, 'webhook_type' => 'github'
    )
    expect(import_data.credentials[:webhook_token]).to be_present
    expect(project.auto_devops_enabled?).to be(true)
  end

  context 'when the import asked not to mirror' do
    let(:params) { { enable_mirroring: false } }

    it 'neither flags the project nor registers a webhook' do
      expect(octokit).not_to receive(:create_hook)

      expect(service.execute({}, :github)[:status]).to eq(:success)
      expect(project.reload.import_data&.data.to_h).not_to include('is_mirror')
    end
  end

  it 'leaves a Gitea import alone: its legacy client has no octokit reader' do
    expect(octokit).not_to receive(:create_hook)

    expect(service.execute({}, :gitea)[:status]).to eq(:success)
    expect(project.reload.import_data.data).not_to include('webhook_type')
  end

  it 'warns, rather than failing the import, when the webhook cannot be created' do
    allow(octokit).to receive(:create_hook).and_raise(Octokit::Forbidden.new(body: 'no admin rights'))

    result = service.execute({}, :github)

    expect(result[:status]).to eq(:success)
    expect(result[:project]).to eq(project)
    expect(result[:warning]).to include('no admin rights')
  end
end
