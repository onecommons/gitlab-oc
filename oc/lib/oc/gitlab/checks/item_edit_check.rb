# frozen_string_literal: true

module OC
  module Gitlab
    module Checks
      # Refuses a push that edits this installation's own issue files in a way
      # it cannot apply: a field that cannot change offline, a change the pusher
      # may not make, or a field that changed since the pusher's copy. The
      # whole push is refused, and the edits are applied after it lands
      # (ItemEditsWorker).
      #
      # Only edits to existing issue files: every other file the installation
      # writes stays ignored, since refusing them would turn pushes that work
      # today into refusals.
      class ItemEditCheck < ::Gitlab::Checks::BaseSingleChecker
        MAX_ITEMS = 100
        MAX_BYTES = 1.megabyte

        def validate!
          return true unless validating?

          paths = ::OC::WorkItems::ItemEdit.changed_paths(project.repository, oldrev, newrev)
          return true if paths.empty?

          check_limits!(paths)
          paths.each { |path| check_item!(path) }

          true
        rescue ::OC::WorkItems::ItemEdit::Error => error
          raise ::Gitlab::GitAccess::ForbiddenError,
            "#{::OC::WorkItems::SyncFile::PUSH_PREFIX} #{error.message}"
        end

        private

        # Our own sync commits change these files on every sync, from a
        # database that has already moved on; refusing one would stop syncing,
        # and FullSyncWorker swallows the refusal.
        def validating?
          branch_ref? && branch_name == ::OC::WorkItems::SYNC_BRANCH && update? &&
            !::OC::WorkItems.own_sync_commit?(project.repository.commit(newrev)&.safe_message)
        end

        def check_limits!(paths)
          if paths.size > MAX_ITEMS
            fail!(paths.first, "this push edits #{paths.size} issues; at most #{MAX_ITEMS} can be edited at once")
          end

          return if project.work_items_sync_enabled?(recording: false)

          fail!(paths.first, 'issues are not edited offline while work items sync is off for this project')
        end

        def check_item!(path)
          edit = ::OC::WorkItems::ItemEdit.diff(path: path, old_yaml: content_at(oldrev, path),
            new_yaml: content_at(newrev, path))
          return if edit.empty?

          issue = project.issues.find_by_iid(edit.iid)
          fail!(path, "issue ##{edit.iid} does not exist here") unless issue

          check_conflicts!(edit, issue)

          problem = ::OC::WorkItems::ItemEditService.new(project, user_access.user).preflight(edit, issue)
          fail!(path, "issue ##{edit.iid} cannot be edited by you: #{problem}") if problem
        end

        # Only the fields this push changes: a comment left on the web a moment
        # ago does not stand in the way of an unrelated title edit. A refusal
        # also syncs the item, so "pull and push again" works even when the
        # change was never committed (a sync that failed, a hook that did not
        # fire).
        def check_conflicts!(edit, issue)
          current = ::OC::WorkItems::RecordSerializer.new.to_yaml(issue)
          fail!(edit.path, "issue ##{edit.iid} cannot be edited offline") unless current.is_a?(String)

          conflicts = edit.statuses(current).filter_map { |key, status| key if status == :conflict }
          return if conflicts.empty?

          ::OC::WorkItems.enqueue_sync(issue, user_access.user)
          what = ::OC::WorkItems::ItemEdit.describe(conflicts.first)
          fail!(edit.path, "issue ##{edit.iid}: #{what} changed since your copy; pull and push again")
        end

        def content_at(revision, path)
          blob = project.repository.blob_at(revision, path)
          fail!(path, "is larger than #{MAX_BYTES / 1.megabyte} MiB") if blob.size > MAX_BYTES

          blob.load_all_data!
          blob.data
        end

        def fail!(path, message)
          raise ::OC::WorkItems::ItemEdit::Error.new(message, path: path)
        end
      end
    end
  end
end
