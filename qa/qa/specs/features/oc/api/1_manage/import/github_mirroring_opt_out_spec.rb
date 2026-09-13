# frozen_string_literal: true

module QA
  # The fork pull-mirrors every GitHub import, so the interesting case is the
  # caller that says no: nothing should be set up, and the fetch endpoint
  # should say the project is not mirroring rather than go and fetch.
  RSpec.describe 'OneCommons GitHub import API', :github, :requires_admin, feature_category: :importers do
    include_context 'with github import'

    # The fork's own fixture. Upstream's default belongs to GitLab's QA
    # account, which cannot be imported from here.
    let(:github_repo) { ENV.fetch('QA_GITHUB_IMPORT_REPOSITORY', 'aszs/gitlab-qa-import-fixture') }

    # API only: the screenshot the framework takes on failure would start a
    # browser to photograph nothing. capybara-screenshot hooks in through
    # RSpec.configure, so its after(:each) runs *after* a group-level one --
    # restoring the flag there would be too late. Context scope brackets both.
    before(:context) do
      Capybara::Screenshot.autosave_on_failure = false
    end

    after(:context) do
      Capybara::Screenshot.autosave_on_failure = true
    end

    before do
      QA::Support::Helpers::ImportSource.enable('github')
    end

    it 'allows an API caller to opt out of the default continuous mirroring' do
      project = Resource::ProjectImportedFromGithub.fabricate_via_api! do |resource|
        resource.name = "github-import-without-mirroring-#{SecureRandom.hex(4)}"
        resource.group = group
        resource.github_personal_access_token = Runtime::Env.github_access_token
        resource.github_repository_path = github_repo
        resource.api_client = user_api_client
        resource.enable_mirroring = false
      end

      response = Support::API.post(
        Runtime::API::Request.new(user_api_client, "#{project.api_get_path}/mirror/fetch").url,
        {}
      )

      expect(response.code).to eq(Support::API::HTTP_STATUS_CREATED)
      expect(Support::API.parse_body(response)).to eq(currently_mirroring: false)
    end
  end
end
