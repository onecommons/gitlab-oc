# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'

RSpec.describe 'Unfurl project templates', feature_category: :source_code_management do
  using RSpec::Parameterized::TableSyntax

  let(:template_files) do
    {
      'application_blueprint' => %w[ensemble-template.yaml .gitlab-ci.yml],
      'ansible_blueprint' => %w[ensemble-template.yaml playbook-create.yaml .gitlab-ci.yml],
      'terraform_blueprint' => %w[ensemble-template.yaml terraform/main.tf .gitlab-ci.yml],
      'unfurl_dashboard' => %w[unfurl.yaml ensemble/ensemble.yaml .gitlab-ci.yml],
      'unfurl_testbed' => %w[unfurl.yaml ensemble/ensemble.yaml .gitlab-ci.yml]
    }
  end

  let(:vendored_templates) { %w[unfurl_dashboard unfurl_testbed] }

  it 'provides every selectable Unfurl template as a cloneable repository with its initial configuration' do
    template_files.each do |template_name, expected_files|
      template = Gitlab::ProjectTemplate.find(template_name)

      expect(template).to be_present
      expect(template.archive_path).to exist

      within_template_repository(template) do |repository_path|
        branch, status = Open3.capture2('git', '-C', repository_path, 'branch', '--show-current')

        expect(status).to be_success
        expect(branch.strip).to eq('main')

        expected_files.each do |path|
          expect(File).to exist(File.join(repository_path, path)),
            "expected #{template_name} to contain #{path}"
        end

        next unless vendored_templates.include?(template_name)

        unfurl_config = File.read(File.join(repository_path, 'unfurl.yaml'))

        expect(unfurl_config).to include('https://unfurl.cloud/onecommons/std.git')
      end
    end
  end

  describe 'the settings the vendored templates carry' do
    let(:admin) { create(:admin, :with_namespace) }

    # The README for these archives calls out both settings as the reason they
    # are hand-curated rather than generated.
    where(:template_name, :visibility_level) do
      [
        ['unfurl_dashboard', Gitlab::VisibilityLevel::PRIVATE],
        ['unfurl_testbed', Gitlab::VisibilityLevel::INTERNAL]
      ]
    end

    with_them do
      it 'survives an import', :sidekiq_inline do
        project = import(template_name)

        expect(project).to be_persisted
        expect(project.reload.visibility_level).to eq(visibility_level)
        expect(project.ci_forward_deployment_enabled?).to be(false)
      end
    end

    # The archives predate the fork's own classification, so what a project made
    # from one carries has to come from the classifier, not the tarball.
    it 'classifies a blueprint project from its files', :sidekiq_inline do
      project = import('application_blueprint')

      expect(project.reload.custom_attributes.pluck(:key, :value))
        .to contain_exactly(['unfurl_type', OC::UNFURL_BLUEPRINT])
    end

    def import(name)
      Projects::CreateFromTemplateService.new(
        admin, { template_name: name, namespace_id: admin.namespace.id, path: name }
      ).execute
    end
  end

  def within_template_repository(template)
    Dir.mktmpdir(template.name) do |directory|
      expect(system('tar', '-xzf', template.archive_path.to_s, '-C', directory)).to be(true)

      repository_path = File.join(directory, 'repository')
      expect(system('git', 'clone', '--quiet', File.join(directory, 'project.bundle'), repository_path)).to be(true)

      yield repository_path
    end
  end
end
