# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Invalidating a project\'s Unfurl caches', feature_category: :source_code_management do
  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:project) { create(:project, :repository, :private, namespace: owner.namespace) }

  let(:path) { "/#{project.full_path}/-/invalidate_cache" }

  context 'as someone who can administer the project' do
    before do
      sign_in(owner)

      # The GDK's config/gitlab.yml sets extra.unfurl_server_url under
      # `production: &base`, which the test environment inherits, so without
      # this these examples really do POST to localhost:8081 and report
      # cleared: false whenever no Unfurl server happens to be running.
      stub_config(extra: {})
    end

    it 'reclassifies a project whose recorded type its files contradict' do
      project.record_unfurl_type!(OC::UNFURL_DASHBOARD)

      get "#{path}.json"

      expect(response).to have_gitlab_http_status(:ok)
      expect(Gitlab::Json::SafeParser.parse(response.body)).to eq('cleared' => true)
      expect(project.reset.recorded_unfurl_type).to eq(OC::REGULAR_PROJECT)
    end

    it 'redirects back to the project for a browser' do
      get path

      expect(response).to redirect_to(project_path(project))
    end

    context 'when an Unfurl server is configured' do
      before do
        stub_config(extra: { 'unfurl_server_url' => 'http://unfurl.test' })
        allow(Gitlab::HTTP).to receive(:post)
      end

      it 'asks it to drop the project from its file cache' do
        get "#{path}.json"

        expect(Gitlab::HTTP).to have_received(:post).with(
          'http://unfurl.test/clear_project_file_cache',
          hash_including(query: { auth_project: project.full_path })
        )
        expect(Gitlab::Json::SafeParser.parse(response.body)).to eq('cleared' => true)
      end
    end

    # Everything above stubs Gitlab::HTTP, which proves the request we build
    # but not that an Unfurl server accepts it. Point this at a running one to
    # check the other half:
    #
    #   OC_TEST_UNFURL_SERVER_URL=http://localhost:8081 bundle exec rspec <file>
    #
    # Skipped when unset, so neither CI nor an ordinary run depends on a
    # service being up -- which is what made this spec fail before.
    context 'with a running Unfurl server', if: ENV['OC_TEST_UNFURL_SERVER_URL'].present? do
      before do
        stub_config(extra: { 'unfurl_server_url' => ENV['OC_TEST_UNFURL_SERVER_URL'] })
      end

      it 'clears the project from its file cache' do
        get "#{path}.json"

        expect(response).to have_gitlab_http_status(:ok)
        expect(Gitlab::Json::SafeParser.parse(response.body)).to eq('cleared' => true)
      end
    end

    context 'when the Unfurl server cannot be reached' do
      before do
        stub_config(extra: { 'unfurl_server_url' => 'http://unfurl.test' })
        allow(Gitlab::HTTP).to receive(:post).and_raise(Errno::ECONNREFUSED)
      end

      it 'says so rather than claiming success' do
        get "#{path}.json"

        expect(Gitlab::Json::SafeParser.parse(response.body)).to eq('cleared' => false)
      end
    end
  end

  context 'as someone who only has read access' do
    let_it_be(:reporter) { create(:user) }

    before_all do
      project.add_reporter(reporter)
    end

    before do
      sign_in(reporter)
    end

    it 'is not available' do
      get "#{path}.json"

      expect(response).to have_gitlab_http_status(:not_found)
    end
  end
end
