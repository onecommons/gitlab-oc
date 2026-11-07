# frozen_string_literal: true

module OC
  module Gitlab
    module Checks
      # Refuses a push that adds or changes an issue draft this installation
      # could not read, under any installation's `<uuid>/_incoming/`. Like
      # SyncFileCheck it decides form only, while the person who wrote the
      # draft is still present; whether an assignee exists or the pusher may
      # create labels is the run's business.
      #
      # A sibling of SyncFileCheck rather than part of it: that one reads one
      # file at a fixed path, this one reads whichever drafts the push touched.
      class DraftFileCheck < ::Gitlab::Checks::BaseSingleChecker
        MAX_BYTES = SyncFileCheck::MAX_BYTES

        # `<dir>/_incoming/<name>`, directly: deeper paths are not drafts.
        DRAFT_PATH = %r{\A(?<dir>[^/]+)/#{::OC::WorkItems::DraftFile::DIRECTORY}/(?<name>[^/]+)\z}

        def validate!
          return true unless validating?

          changed_draft_paths.each { |path| check_draft!(path) }

          true
        rescue ::OC::WorkItems::DraftFile::Error => error
          raise ::Gitlab::GitAccess::ForbiddenError,
            "#{::OC::WorkItems::SyncFile::PUSH_PREFIX} #{error.message}"
        end

        private

        # Branch creation is exempt for the reason SyncFileCheck gives: a purge
        # replay recreates the branch through these hooks.
        def validating?
          branch_ref? && branch_name == ::OC::WorkItems::SYNC_BRANCH && update?
        end

        # Drafts the push adds or changes. A deletion is never refused: it is
        # how a user cancels a draft, and how the installation cleans one up.
        def changed_draft_paths
          diff = ::Gitlab::Git::DiffTree.new(oldrev, newrev)

          project.repository.find_changed_paths([diff]).filter_map do |changed|
            next if changed.deleted_file?

            match = DRAFT_PATH.match(changed.path)
            changed.path if match && ::OC::WorkItems::DraftFile.draft_path?(changed.path, match[:dir])
          end
        end

        def check_draft!(path)
          draft = ::OC::WorkItems::DraftFile.parse(content_at(path), path: path)
          directory = DRAFT_PATH.match(path)[:dir]
          siblings = draft_keys_in(directory)

          if siblings.count(draft.key) > 1
            fail!(path, "another draft in #{directory}/#{::OC::WorkItems::DraftFile::DIRECTORY}/ " \
              "has the key #{draft.key.inspect}; .yml and .yaml name the same draft")
          end

          # Visibility and recorded keys are this installation's; another
          # installation's drafts are checked for form only.
          return unless directory == ::OC::WorkItems.instance_directory

          if draft.confidential? && !project.private?
            fail!(path, '"confidential: true" is only allowed on private projects')
          end

          check_references!(draft, siblings)
        end

        # A key is known when a draft for it is on the branch as pushed, or an
        # issue was already created from it. The database is read only for
        # keys the branch does not answer.
        def check_references!(draft, siblings)
          missing = draft.draft_references - siblings
          return if missing.empty?

          missing -= ::OC::WorkItems::Draft.for_project(project).where(key: missing).pluck(:key) # rubocop:disable CodeReuse/ActiveRecord -- one indexed lookup on the push path
          return if missing.empty?

          fail!(draft.path, "#draft:#{missing.first} names no draft in this push and no issue created " \
            'from one')
        end

        # Once per directory, however many of its drafts the push changed.
        def draft_keys_in(directory)
          @draft_keys ||= {}
          @draft_keys[directory] ||= begin
            tree = project.repository.tree(newrev, "#{directory}/#{::OC::WorkItems::DraftFile::DIRECTORY}")

            tree.blobs.filter_map do |blob|
              ::OC::WorkItems::DraftFile.key_for(blob.path) if
                ::OC::WorkItems::DraftFile.draft_path?(blob.path, directory)
            end
          end
        end

        def content_at(path)
          blob = project.repository.blob_at(newrev, path)
          fail!(path, "is larger than #{MAX_BYTES / 1.kilobyte} KiB") if blob.size > MAX_BYTES

          blob.load_all_data!
          blob.data
        end

        def fail!(path, message)
          raise ::OC::WorkItems::DraftFile::Error.new(message, path: path)
        end
      end
    end
  end
end
