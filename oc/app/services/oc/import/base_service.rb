# frozen_string_literal: true

module OC
  module Import
    module BaseService
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      private

      override :success
      def success(project, warning: nil)
        explicitly_enable_auto_devops(project)

        super
      end

      # OC Change #928
      # Auto DevOps enabled implicitly, from the instance or group setting, is
      # switched off again by a failing first pipeline. Enabled on the project
      # it stays on, so an import whose first pipeline fails still builds once
      # the user has fixed it.
      def explicitly_enable_auto_devops(project)
        project.auto_devops_enabled = true
        project.save!
      end
    end
  end
end
