# frozen_string_literal: true

module OC
  module Repositories
    # Tells the Unfurl server which of a push's files it should re-read.
    # Without it the server keeps serving whatever it cached when it last
    # cloned, so a pushed change to unfurl.yaml or an ensemble template stays
    # invisible until something else evicts it.
    class ProjectUnfurlCacheWorker
      include ::ApplicationWorker

      data_consistency :always

      sidekiq_options retry: 3

      feature_category :source_code_management
      urgency :high

      # The server's populate_cache is idempotent.
      idempotent!

      # Files the Unfurl server reads. See Gitlab::FileDetector.
      UNFURL_FILE_TYPES = %i[
        deployment_json
        ensemble_json
        ensemble_template_yaml
        ensemble_yaml
        environments_json
        service_template_py
        service_template_yaml
        unfurl_json
        unfurl_types_json
        unfurl_yaml
      ].freeze

      def perform(project_id, ref, oldrev, newrev)
        return if unfurl_server_url.blank?

        project = ::Project.find_by_id(project_id)
        return unless project&.repository&.exists?

        commit = project.repository.commit(newrev)
        return unless commit

        files = changed_unfurl_files(project.repository, oldrev, newrev)
        return if files.empty?

        # Whether the server may record this commit as the branch's head.
        #
        # It keeps that head in a key with no ancestry, so it cannot reject an
        # older commit arriving late -- and this worker is the first unordered
        # writer it has had: `retry: 3` can land a retried job after a later
        # push. A late one would send watchers back to a commit the branch has
        # already left, and they would keep being told so.
        #
        # The repository is right here, so the answer comes from asking it. A
        # tag is excluded because it has no moving head to report.
        # `.present?` because branch_ref? answers with a match position or nil
        # rather than a boolean, and the query would otherwise carry an empty
        # `sethead=` for a tag where it means to say false.
        sethead = ::Gitlab::Git.branch_ref?(ref).present? &&
          project.repository.commit(ref)&.sha == commit.sha

        # One request for the push, not one per file: the commit, branch and
        # visibility are the same for all of them, and the server keys a cache
        # entry per path from the batch.
        #
        # Gitlab::HTTP blocks the local network by default, and this posts
        # straight to the unfurl-server container.
        ::Gitlab::HTTP.post(
          "#{unfurl_server_url}/populate_cache",
          query: {
            auth_project: project.path_with_namespace,
            # 15.11 sent visibility_level_name, which is gone; visibility is
            # the same string the server has always been given.
            visibility: project.visibility,
            latest_commit: commit.sha,
            branch: ref,
            sethead: sethead
          },
          headers: { 'Content-Type' => 'application/json' },
          body: ::Gitlab::Json.dump(files: files),
          allow_local_requests: true
        )
      end

      private

      def unfurl_server_url
        ::OC::Repositories::UnfurlServer.internal_url
      end

      def unfurl_file?(filename)
        UNFURL_FILE_TYPES.include?(::Gitlab::FileDetector.type_of(filename))
      end

      # Every Unfurl file the push touched, as the batch the server expects.
      #
      # The whole range rather than the tip commit: a file changed early in a
      # push and left alone afterwards is still stale in the server's cache,
      # and reading the tip's diff alone missed it. find_changed_paths is one
      # RPC that returns paths and a status without any content, so this costs
      # less than the diff collection it replaces -- and is not subject to
      # `diff_max_files`, which silently truncated a large push.
      #
      # Renames are deliberately not detected: without find_renames a rename
      # arrives as a DELETED and an ADDED path, which is exactly the pair of
      # cache operations it needs.
      def changed_unfurl_files(repository, oldrev, newrev)
        changed_paths(repository, oldrev, newrev).filter_map do |change|
          path = change.path
          old_path = change.old_path

          if change.status == :DELETED
            { path: old_path.presence || path, removed: true } if unfurl_file?(old_path.presence || path)
          elsif unfurl_file?(path)
            { path: path, removed: false }
          end
        end.uniq
      end

      # A branch created by this push has no `oldrev` to diff against, so the
      # new commit is compared with its own parents instead.
      def changed_paths(repository, oldrev, newrev)
        if ::Gitlab::Git.blank_ref?(oldrev)
          repository.find_changed_paths([newrev])
        else
          repository.find_changed_paths([::Gitlab::Git::DiffTree.new(oldrev, newrev)])
        end
      end
    end
  end
end
