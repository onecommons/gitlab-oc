# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::PullMirrors::Webhook::GithubService, feature_category: :source_code_management do
  let_it_be_with_reload(:project) do
    create(:project, import_url: 'https://github.example.test/team/source.git')
  end

  let(:octokit) { instance_double(Octokit::Client) }
  let(:client) { instance_double(Gitlab::GithubImport::Client, octokit: octokit) }
  let(:repo) { { id: 42, full_name: 'team/source' } }
  let(:service) { described_class.new(project, client, repo_name: 'team/source') }

  # Octokit answers with Sawyer::Resource, not a Hash, and Sawyer refuses to
  # read `config` off one. A plain hash here would pass while the real thing
  # raises, which is exactly what it did.
  let(:hook) { sawyer(id: 73, config: { url: service.fetch_endpoint_url }) }

  def sawyer(attrs)
    Sawyer::Resource.new(Sawyer::Agent.new('https://api.github.com'), attrs)
  end

  before do
    allow(client).to receive(:repository).with('team/source').and_return(repo)
  end

  describe 'create' do
    it 'registers a push hook on the fetch endpoint and stores its secret' do
      allow(octokit).to receive(:hooks).with(42).and_return([])

      expect(octokit).to receive(:create_hook) do |repository_name, hook_type, config, options|
        expect(repository_name).to eq('team/source')
        expect(hook_type).to eq('web')
        expect(config).to include(url: service.fetch_endpoint_url, content_type: 'json', secret: be_present)
        expect(options).to eq(events: ['push'], active: true)

        sawyer(id: 73, config: { url: service.fetch_endpoint_url })
      end

      expect(service.execute(:create)[:status]).to eq(:success)
      expect(project.reload.import_data.credentials[:webhook_token]).to be_present
    end

    it 'leaves an existing hook, and its secret, alone' do
      project.build_or_assign_import_data(credentials: { webhook_token: 'already-set' })
      project.import_data.save!

      allow(octokit).to receive(:hooks).with(42).and_return([hook])
      expect(octokit).not_to receive(:create_hook)

      expect(service.execute(:create)[:hook]).to eq(:not_modified)
      expect(project.reload.import_data.credentials[:webhook_token]).to eq('already-set')
    end
  end

  describe 'delete' do
    it 'removes the hook and clears its secret' do
      project.build_or_assign_import_data(credentials: { webhook_token: 'old-token' })
      project.import_data.save!

      allow(octokit).to receive(:hooks).with(42).and_return([hook])
      expect(octokit).to receive(:remove_hook).with('team/source', 73)

      expect(service.execute(:delete)[:status]).to eq(:success)
      expect(project.reload.import_data.credentials[:webhook_token]).to be_nil
    end
  end

  it 'reports a GitHub error rather than raising it' do
    allow(octokit).to receive(:hooks).and_raise(Octokit::Forbidden.new(body: 'no admin rights'))

    result = service.execute(:create)

    expect(result[:status]).to eq(:error)
    expect(result[:message]).to include('no admin rights')
  end
end
