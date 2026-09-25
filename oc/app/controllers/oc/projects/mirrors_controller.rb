# frozen_string_literal: true

module OC
  module Projects
    module MirrorsController
      extend ::Gitlab::Utils::Override
      extend ActiveSupport::Concern

      # OC Change #906 -- a pull mirror's settings are the one checkbox the
      # fork's section renders; upstream's #update is push-mirror only.
      override :update
      def update
        return super unless project.mirror?

        project.build_or_assign_import_data(data: { mirror_enabled: mirror_enabled_param })
        project.import_data.save!

        flash[:notice] = _('Mirroring settings were successfully updated.')

        respond_to do |format|
          format.html { redirect_to_repository_settings(project, anchor: 'js-push-remote-settings') }
          format.json { render json: project.import_data.data }
        end
      end

      # OC Change #1128 -- manual sync from the settings page
      override :update_now
      def update_now
        return super unless project.mirror?

        project.ensure_repository

        ref = project.default_branch_or_main
        old_head = project.repository.commit(ref)&.id
        project.repository.fetch_as_mirror(project.unsafe_import_url, forced: true)
        new_head = project.repository.commit(ref)&.id

        if new_head != old_head
          CreatePipelineWorker.perform_async(project.id, project.owner.id, ref, :push)
          announce_mirror_sync(ref, old_head, new_head)
        end

        flash[:notice] = _('Repository updated successfully.')
        redirect_to_repository_settings(project, anchor: 'js-push-remote-settings')
      end

      private

      # A mirror pull announces itself nowhere else: it fires no hook and
      # creates no Event row. See OC::Repositories::MirrorSyncedEvent.
      def announce_mirror_sync(ref, old_sha, new_sha)
        ::Gitlab::EventStore.publish(
          ::OC::Repositories::MirrorSyncedEvent.new(data: {
            project_id: project.id, ref: ref, old_sha: old_sha, new_sha: new_sha
          }.compact)
        )
      end

      # The checkbox is bound to the predicate, so the field is named for it.
      def mirror_enabled_param
        submitted = params.require(:project)

        ActiveModel::Type::Boolean.new.cast(submitted[:mirror_enabled?] || submitted[:mirror_enabled])
      end
    end
  end
end
