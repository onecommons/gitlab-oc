# frozen_string_literal: true

module OC
  module ProjectTemplateTestHelper
    extend ::Gitlab::Utils::Override

    override :all_templates
    def all_templates
      %w[
        application_blueprint unfurl_testbed unfurl_dashboard
        terraform_blueprint ansible_blueprint
      ]
    end
  end
end
