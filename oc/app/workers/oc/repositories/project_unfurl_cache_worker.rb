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
              removed: removed
            },
            allow_local_requests: true
          )
        end
      end

      private

      def unfurl_server_url
        ::Gitlab.config.extra['unfurl_server_url']
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
