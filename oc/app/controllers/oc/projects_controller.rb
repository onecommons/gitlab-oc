# frozen_string_literal: true

module OC
  module ProjectsController
    extend ActiveSupport::Concern

    prepended do
      skip_before_action :authenticate_user!, only: :overview
    end

    # The Unfurl Cloud blueprint page, a Vue app from the oc-pages package.
    def overview
      @id = @ref = repository_root
      @path = ''
      @ref_type = 'heads'
      @project = @project.present(current_user: current_user)
      @live_preview_url = live_preview_url

      render 'projects/overview'
    end

    private

    # A group CI variable named after the project holds the URL of its live deployment.
    def live_preview_url
      key = "__UNFURL_CLOUD_URL_#{project.full_path.gsub('/', '__').tr('-', '_')}"

      project.group&.variables&.find { |variable| variable.key == key }&.value
    end
  end
end
