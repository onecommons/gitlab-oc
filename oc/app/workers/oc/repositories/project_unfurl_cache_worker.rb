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
        unfurl_json
        unfurl_types_json
        unfurl_yaml
      ].freeze

      def perform(project_id, ref, commit_id)
        return if unfurl_server_url.blank?

        project = ::Project.find_by_id(project_id)
        return unless project&.repository&.exists?

        commit = project.repository.commit(commit_id)
        return unless commit

        # Whether the server may record this commit as the branch's head.
        #
        # It keeps that head in a key with no ancestry, so it cannot reject an
        # older commit arriving late -- and this worker is the first unordered
        # writer it has had: `retry: 3` can land a retried job after a later
        # push, and one push touching several files is that many sequential
        # calls. A late one would send watchers back to a commit the branch has
        # already left, and they would keep being told so.
        #
        # The repository is right here, so the answer comes from asking it.
        # Hoisted out of the loop deliberately: every file in one push shares
        # this answer, and a five-file push should not ask five times. A tag is
        # excluded because it has no moving head to report.
        # `.present?` because branch_ref? answers with a match position or nil
        # rather than a boolean, and the query would otherwise carry an empty
        # `sethead=` for a tag where it means to say false.
        sethead = ::Gitlab::Git.branch_ref?(ref).present? &&
          project.repository.commit(ref)&.sha == commit.sha

        unfurl_file_diffs_for(commit).each do |diff|
          removed = diff.deleted_file? || !unfurl_file?(diff.new_path)

          # Gitlab::HTTP blocks the local network by default, and this posts
          # straight to the unfurl-server container.
          ::Gitlab::HTTP.post(
            "#{unfurl_server_url}/populate_cache",
            query: {
              auth_project: project.path_with_namespace,
              # 15.11 sent visibility_level_name, which is gone; visibility is
              # the same string the server has always been given.
              visibility: project.visibility,
              path: removed ? diff.old_path : diff.new_path,
              latest_commit: commit.sha,
              branch: ref,
              removed: removed,
              sethead: sethead
            },
            allow_local_requests: true
          )
        end
      end

      private

      def unfurl_server_url
        ::OC::Repositories::UnfurlServer.internal_url
      end

      def unfurl_file?(filename)
        UNFURL_FILE_TYPES.include?(::Gitlab::FileDetector.type_of(filename))
      end

      # Was this file an Unfurl file, or has it become one?
      def unfurl_file_diffs_for(commit)
        commit.diffs.diff_files.filter { |d| unfurl_file?(d.old_path) || unfurl_file?(d.new_path) }
      end
    end
  end
end
