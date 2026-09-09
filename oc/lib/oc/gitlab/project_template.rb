# frozen_string_literal: true

module OC
  module Gitlab
    module ProjectTemplate
      extend ActiveSupport::Concern

      LOGO = 'illustrations/unfurl-box-default.svg'

      class_methods do
        extend ::Gitlab::Utils::Override

        def localized_oc_templates_table
          [
            ::Gitlab::ProjectTemplate.new('application_blueprint', 'Application Blueprint', _('Application blueprint scaffolding'), 'https://unfurl.cloud/onecommons/project-templates/application-blueprint', LOGO),
            ::Gitlab::ProjectTemplate.new('unfurl_testbed', 'Testbed', _('Shared Testbed'), 'https://unfurl.cloud/onecommons/project-templates/testbed', LOGO),
            ::Gitlab::ProjectTemplate.new('unfurl_dashboard', 'Dashboard', _('Home Dashboard'), 'https://unfurl.cloud/onecommons/project-templates/dashboard', LOGO),
            ::Gitlab::ProjectTemplate.new('terraform_blueprint', 'Terraform Blueprint', _('Generic Terraform blueprint scaffolding'), 'https://unfurl.cloud/onecommons/project-templates/terraform-blueprint', LOGO),
            ::Gitlab::ProjectTemplate.new('ansible_blueprint', 'Ansible Blueprint', _('Generic Ansible blueprint scaffolding'), 'https://unfurl.cloud/onecommons/project-templates/ansible-blueprint', LOGO)
          ].freeze
        end

        # Unfurl Cloud offers Unfurl templates only, so this replaces the table
        # rather than appending to it.
        override :all
        def all
          localized_oc_templates_table
        end
      end
    end
  end
end
