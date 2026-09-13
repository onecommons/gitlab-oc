# frozen_string_literal: true

module OC
  module Import
    module BaseService
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      # OC Change -- mirroring by default
      # TODO: don't enable this by default once we get the settings pane finished
      def initialize(client, user, params)
        super

        @params[:enable_mirroring] = true unless @params.key?(:enable_mirroring)
      end

      private

      def mirroring_requested?
        ::Gitlab::Utils.to_boolean(params[:enable_mirroring], default: false)
      end

      override :success
      def success(project, warning: nil)
        set_mirror_flag(project) if mirroring_requested?
        explicitly_enable_auto_devops(project)

        super
      end

      # OC Change #863 -- pull mirroring
      # There is no `mirror` column to set: upstream's is gated on an EE
      # feature, so the request is recorded in the import data instead.
      def set_mirror_flag(project)
        project.build_or_assign_import_data(data: { is_mirror: true, mirror_enabled: true })
        project.import_data.save!
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
