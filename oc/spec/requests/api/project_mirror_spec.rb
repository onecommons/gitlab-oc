# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'GitHub pull-mirror webhooks', feature_category: :source_code_management do
  let_it_be_with_reload(:project) { create(:project, :repository) }

  let(:webhook_token) { 'test-webhook-token' }
  let(:payload) { Gitlab::Json.dump(ref: 'refs/heads/main') }
  let(:signature) { "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), webhook_token, payload)}" }
  let(:repository) { instance_double(Repository, empty?: false, root_ref: 'main') }

  before do
    project.update!(import_type: 'github', import_url: 'https://github.example.test/team/source.git')
    project.record_unfurl_type!(OC::REGULAR_PROJECT)
    project.build_or_assign_import_data(
      data: { is_mirror: true, mirror_enabled: true },
      credentials: { webhook_token: webhook_token }
    )
    project.import_data.save!
  end

  def deliver_webhook(signature: self.signature)
    post api("/projects/#{project.id}/mirror/fetch"), params: payload,
      headers: {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_X_GITHUB_EVENT' => 'push',
        'HTTP_X_HUB_SIGNATURE_256' => signature
      }
  end

  # The endpoint fetches through whichever Project it loads, so the double has
  # to be attached to that instance rather than the one built here.
  def stub_loaded_project(&block)
    allow_next_found_instance_of(Project) do |loaded|
      allow(loaded).to receive_messages(ensure_repository: nil, repository: repository)

      yield(loaded) if block
    end
  end

  it 'rejects a delivery whose HMAC does not match the import webhook token' do
    stub_loaded_project { |loaded| expect(loaded).not_to receive(:ensure_repository) }

    deliver_webhook(signature: 'sha256:not-the-token')

    expect(response).to have_gitlab_http_status(:forbidden)
  end

  it 'fetches a valid delivery and starts a push pipeline for its branch' do
    old_head_commit = instance_double(Commit, id: 'old-upstream-sha')
    head_commit = instance_double(Commit, id: 'new-upstream-sha')

    stub_loaded_project
    allow(repository).to receive(:fetch_as_mirror).with(project.unsafe_import_url, forced: true)
    allow(repository).to receive(:commit).with('main').and_return(old_head_commit, head_commit)
    allow(repository).to receive(:head_commit).and_return(head_commit)
    allow(CreatePipelineWorker).to receive(:perform_async)

    deliver_webhook

    expect(response).to have_gitlab_http_status(:created)
    expect(json_response['new_head_commit']).to eq('new-upstream-sha')
    expect(CreatePipelineWorker).to have_received(:perform_async).with(project.id, project.owner.id, 'main', :push)
  end

  it 'does not start a pipeline when a valid delivery leaves the HEAD unchanged' do
    head_commit = instance_double(Commit, id: 'unchanged-upstream-sha')

    stub_loaded_project
    allow(repository).to receive(:fetch_as_mirror).with(project.unsafe_import_url, forced: true)
    allow(repository).to receive(:commit).with('main').and_return(head_commit)
    allow(repository).to receive(:head_commit).and_return(head_commit)
    allow(CreatePipelineWorker).to receive(:perform_async)

    deliver_webhook

    expect(response).to have_gitlab_http_status(:created)
    expect(json_response['new_head_commit']).to eq('unchanged-upstream-sha')
    expect(CreatePipelineWorker).not_to have_received(:perform_async)
  end

  it 'ignores a delivery for a project whose mirroring has been switched off' do
    project.build_or_assign_import_data(data: { mirror_enabled: false })
    project.import_data.save!

    stub_loaded_project { |loaded| expect(loaded).not_to receive(:ensure_repository) }

    deliver_webhook

    expect(response).to have_gitlab_http_status(:created)
    expect(json_response['currently_mirroring']).to be(false)
  end

  # Minting the secret is what authenticates every later fetch, and a fetch
  # creates a pipeline. On a public project user_project proves only that the
  # caller can read, so without an explicit check these endpoints are open.
  describe 'managing the webhook' do
    let(:outsider) { create(:user) }

    before do
      project.update!(visibility_level: Gitlab::VisibilityLevel::PUBLIC)
    end

    it 'refuses an anonymous caller, though a public project is readable by one' do
      post api("/projects/#{project.id}/mirror/hook/manual")

      expect(response).to have_gitlab_http_status(:unauthorized)
    end

    it 'refuses a signed-in user who cannot administer the project' do
      post api("/projects/#{project.id}/mirror/hook/manual", outsider)

      expect(response).to have_gitlab_http_status(:forbidden)
    end

    # The permission is mirror_available-gated, exactly as upstream's own
    # Projects::MirrorsController#check_mirror_available! already is, so the
    # fork's settings section and these endpoints go away together.
    it 'refuses even the owner when the instance has mirroring switched off' do
      stub_application_setting(mirror_available: false)

      post api("/projects/#{project.id}/mirror/hook/manual", project.first_owner)

      expect(response).to have_gitlab_http_status(:forbidden)
    end

    it 'lets an administrator of the project mint the secret and clear it again' do
      post api("/projects/#{project.id}/mirror/hook/manual", project.first_owner)

      expect(response).to have_gitlab_http_status(:created)
      expect(json_response['secret']).to be_present
      expect(project.reload.import_data.credentials[:webhook_token]).to eq(json_response['secret'])

      delete api("/projects/#{project.id}/mirror/hook/manual", project.first_owner)

      expect(response).to have_gitlab_http_status(:ok)
      expect(project.reload.import_data.credentials[:webhook_token]).to be_nil
    end
  end

  # The fetch endpoint waives CSRF because a signed delivery carries no token.
  # That waiver is scoped by route, and nothing else proves it stays scoped.
  describe 'the CSRF waiver', :allow_forgery_protection do
    let(:head_commit) { instance_double(Commit, id: 'session-fetch-sha') }

    it 'lets a session-authenticated caller fetch without a CSRF token' do
      stub_loaded_project
      allow(repository).to receive(:fetch_as_mirror).with(project.unsafe_import_url, forced: true)
      allow(repository).to receive_messages(commit: head_commit, head_commit: head_commit)
      login_as(project.first_owner)

      post api("/projects/#{project.id}/mirror/fetch")

      expect(response).to have_gitlab_http_status(:created)
      expect(json_response['new_head_commit']).to eq('session-fetch-sha')
    end

    # Read with the example above, which is the control: the same session, with
    # no CSRF token either, is accepted on the fetch route. So this 401 is the
    # waiver not applying, rather than session auth not working here at all.
    it 'does not waive it for the webhook management endpoints' do
      login_as(project.first_owner)

      post api("/projects/#{project.id}/mirror/hook/manual")

      expect(response).to have_gitlab_http_status(:unauthorized)
    end
  end

  it 'answers a ping delivery without fetching' do
    head_commit = instance_double(Commit, id: 'current-sha')

    stub_loaded_project
    allow(repository).to receive(:head_commit).and_return(head_commit)
    expect(repository).not_to receive(:fetch_as_mirror)

    post api("/projects/#{project.id}/mirror/fetch"), params: payload,
      headers: {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_X_GITHUB_EVENT' => 'ping',
        'HTTP_X_HUB_SIGNATURE_256' => signature
      }

    expect(response).to have_gitlab_http_status(:created)
    expect(json_response['ping']).to eq('pong')
  end

  it 'refuses to fetch a dashboard still importing from the dashboard template' do
    project.update!(import_url: "#{Gitlab::ProjectTemplate.find(:unfurl_dashboard).preview}.git")

    stub_loaded_project
    expect(repository).not_to receive(:fetch_as_mirror)

    deliver_webhook

    expect(response).to have_gitlab_http_status(:bad_request)
  end
end
