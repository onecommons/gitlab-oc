# frozen_string_literal: true

module QA
  # The other half of the opt-out case: an ordinary browser import is mirrored,
  # and the fork's repository settings section is what turns that off and on.
  RSpec.describe 'OneCommons GitHub import', :github, :requires_admin, feature_category: :importers do
    include_context 'with github import'

    # The fork's own fixture. Upstream's default belongs to GitLab's QA
    # account, which cannot be imported from here.
    let(:github_repo) { ENV.fetch('QA_GITHUB_IMPORT_REPOSITORY', 'aszs/gitlab-qa-import-fixture') }

    let(:imported_project) do
      Resource::ProjectImportedFromGithub.init do |project|
        project.import = true
        project.group = group
        project.github_personal_access_token = Runtime::Env.github_access_token
        project.github_repository_path = github_repo
        project.api_client = api_client
      end
    end

    before do
      QA::Support::Helpers::ImportSource.enable('github')

      Flow::Login.sign_in(as: user)
      Page::Main::Menu.perform(&:go_to_create_project)
      Page::Project::New.perform do |project_page|
        project_page.click_import_project
        project_page.click_github_link
      end
    end

    # Removes the webhook this spec put on the real repository, through the
    # fork's own endpoint -- which is the only exercise that endpoint gets, and
    # without it every run leaves a dead hook behind (GitHub caps a repo at 20).
    after do
      next unless imported_project.exists?

      response = Support::API.delete(
        Runtime::API::Request.new(api_client, "#{imported_project.api_get_path}/mirror/hook/github").url,
        payload: { personal_access_token: Runtime::Env.github_access_token }
      )

      # 304 is the endpoint saying there was no hook to remove, which is a
      # clean teardown after an example that failed before creating one.
      next if [Support::API::HTTP_STATUS_OK, 304].include?(response.code)

      raise "Could not remove the pull-mirroring webhook (#{response.code}); it is still on #{github_repo}"
    end

    it 'enables continuous mirroring for a project imported through the browser' do
      Page::Project::Import::Github.perform do |import_page|
        import_page.add_personal_access_token(Runtime::Env.github_access_token)
        import_page.import!(github_repo, group.full_path, imported_project.name)
      end

      # Wait on the API, not the import table. Every refresh of that page hits
      # GitHub's search endpoint, which allows 30 requests a minute, and this
      # spec is about the settings section rather than upstream's import UI --
      # which upstream's own spec already covers.
      expect_project_import_finished_successfully

      imported_project.visit!
      Page::Project::Menu.perform(&:go_to_repository_settings)
      Page::Project::Settings::Repository.perform do |settings|
        settings.expand_mirroring_repositories do
          # Pajamas hides the native input behind a styled label, so Capybara
          # finds it by label text but rejects it as invisible; hence visible:
          # :all to read it and allow_label_click to toggle it.
          expect(page).to have_content('This repository is configured as a mirror of')
          expect(page).to have_checked_field('Enable continuous mirroring', visible: :all)

          uncheck('Enable continuous mirroring', allow_label_click: true)
          click_button('Save changes')
          # The flash renders above the section, outside the within_element scope.
          expect(page.document).to have_content('Mirroring settings were successfully updated.')
          expect(page).to have_unchecked_field('Enable continuous mirroring', visible: :all)

          check('Enable continuous mirroring', allow_label_click: true)
          click_button('Save changes')
          expect(page).to have_checked_field('Enable continuous mirroring', visible: :all)

          click_button('Fetch Latest')
          expect(page.document).to have_content('Repository updated successfully.')
        end
      end
    end
  end
end
