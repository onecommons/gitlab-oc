# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Invalidating a project\'s Unfurl caches', feature_category: :source_code_management do
  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:project) { create(:project, :repository, :private, namespace: owner.namespace) }

  let(:path) { "/#{project.full_path}/-/invalidate_cache" }

  context 'as someone who can administer the project' do
    before do
      sign_in(owner)
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
