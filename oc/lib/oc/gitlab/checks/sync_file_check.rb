# frozen_string_literal: true

module OC
  module Gitlab
    module Checks
      # Refuses a push that leaves sync.yml unreadable. Everything else here
      # treats the branch as data and never fails a push over it; a malformed
      # control file is different, because the person who wrote it is still
      # present and no later run can make sense of it.
      #
      # Only the form is decided here. Whether a named user exists or an item
      # has moved is database state the other instance cannot see, so runs
      # wait.
      class SyncFileCheck < ::Gitlab::Checks::BaseSingleChecker
        # So that reading the blob on the push path cannot be turned into work.
        MAX_BYTES = 64.kilobytes

        def validate!
          return true unless validating?

          content = changed_content
          return true if content.nil?

          ::OC::WorkItems::SyncFile.parse(content)

          true
        rescue ::OC::WorkItems::SyncFile::Error => error
          raise ::Gitlab::GitAccess::ForbiddenError,
            "#{::OC::WorkItems::SyncFile::PUSH_PREFIX} #{error.message}"
        end

        private

        # Branch creation is exempt because that is what a purge replay is:
        # purge_own_history! deletes the branch and recommits every foreign file
        # through these same hooks, so a check able to refuse it would fail with
        # the branch already deleted. A bad file arriving that way is inert --
        # a run that cannot read it imports nothing.
        def validating?
          branch_ref? && branch_name == ::OC::WorkItems::SYNC_BRANCH && update?
        end

        # What this push leaves in the file, or nil if it leaves it alone or
        # deletes it -- no file means no declarations.
        def changed_content
          blob = ::OC::WorkItems::SyncFile.changed_blob(project.repository, oldrev, newrev)
          return if blob.nil?

          if blob.size > MAX_BYTES
            raise ::OC::WorkItems::SyncFile::Error,
              "is larger than #{MAX_BYTES / 1.kilobyte} KiB"
          end

          blob.load_all_data!
          blob.data
        end
      end
    end
  end
end
