# frozen_string_literal: true

module OC
  module Projects
    # OC Change -- tells the cloudmap what happened to repositories. Reads
    # oc_cloudmap_events after a stored cursor and reports it to the Unfurl
    # server's POST /cloudmap/analyze, several URLs per request:
    #
    #   add      included projects whose metadata changed, if public;
    #            refreshed with analyze "metadata", which does not clone
    #   private  included projects that exist but are not public
    #   deleted  repositories that were public when they were deleted
    #   moved    {from:, to:} for a public included project whose path
    #            changed, its own or a namespace's above it
    #
    # Included means a blueprint or dashboard, or any project under a group
    # marked OC::GroupCustomAttribute::CLOUDMAP_INCLUDE_ALL_PUBLIC.
    #
    # These are events, not instructions: what each means for a cloudmap
    # record is the server's decision. Visibility and type are judged when
    # sent, not when the row was written. The server writes to the cloudmap
    # with a credential of its own, so none is sent.
    #
    # One commit per run, however many requests it takes: each request only
    # stages, and an empty POST /cloudmap at the end commits what they
    # staged.
    class CloudmapRefreshWorker
      include ApplicationWorker
      include CronjobQueue # rubocop:disable Scalability/CronWorkerContext -- reads a feed spanning every project

      data_consistency :sticky
      # Safe to rerun: the cursor only moves once a run is committed, and the
      # server ignores a change it already has. Deduplicated so a slow run
      # and the next minute's cannot read the same rows.
      idempotent!
      deduplicate :until_executed
      feature_category :source_code_management
      urgency :low
      defer_on_database_health_signal :gitlab_main_org, %i[oc_cloudmap_events projects], 1.minute

      CURSOR_KEY = 'oc:cloudmap:refresh_cursor'
      # Rows read per run; whatever is left waits for the next.
      ROW_LIMIT = 1_000
      EVENTS_PER_REQUEST = 100
      # An id is assigned at insert and becomes visible at commit, so a row
      # can appear behind one already read. Reading only rows at least this
      # old leaves every insert time to commit.
      LAG = 30.seconds
      # How far back a consumer with no stored cursor starts.
      INITIAL_WINDOW = 1.day
      UNFURL_TYPES = [::OC::UNFURL_BLUEPRINT, ::OC::UNFURL_DASHBOARD].freeze

      PROJECT_KINDS = %w[metadata_changed visibility_changed].freeze
      HIERARCHY_KINDS = %w[namespace_moved group_archived group_unarchived group_included].freeze

      def perform
        # Left unread rather than skipped, for when the server is configured.
        return if unfurl_server_url.blank?

        rows = readable_rows
        return if rows.empty?

        events = events_in(rows)
        return unless events.each_slice(EVENTS_PER_REQUEST).all? { |slice| analyze(slice) }
        return unless events.empty? || commit(events)

        self.cursor = rows.last.id
        log_extra_metadata_on_done(:rows, rows.size)
        log_extra_metadata_on_done(:sent, events.size)
      end

      private

      # Contiguous from the cursor: the first row too new to read ends the
      # run, so none after it is read ahead of it.
      def readable_rows
        cutoff = LAG.ago
        ::OC::Projects::CloudmapEvent.after_cursor(cursor).limit(ROW_LIMIT).to_a
          .take_while { |row| row.occurred_at < cutoff }
      end

      # Each event as [list, value], so a request can be cut anywhere.
      def events_in(rows)
        projects = listed_projects(rows).index_by(&:id)

        events = rows.flat_map do |row|
          case row.kind
          when 'project_deleted' then deleted(row)
          when *PROJECT_KINDS then project_events(projects[row.project_id], row.payload['old_path'])
          when *HIERARCHY_KINDS then hierarchy_events(row, projects)
          else []
          end
        end

        events.uniq
      end

      # The included projects among those the rows name: nothing else ever
      # reaches the cloudmap from here, so there is nothing else to report on.
      def listed_projects(rows)
        ids = rows.flat_map { |row| [row.project_id, *Array(row.payload['project_ids'])] }.compact.uniq
        marked_groups = ::GroupCustomAttribute.cloudmap_including_group_ids

        ids.each_slice(ROW_LIMIT).flat_map do |slice|
          named = ::Project.id_in(slice).with_route
          typed = named.with_unfurl_type(UNFURL_TYPES).to_a
          next typed if marked_groups.empty?

          (typed + named.in_namespace(::Group.id_in(marked_groups).self_and_descendant_ids).to_a).uniq
        end
      end

      def project_events(project, old_path)
        return [] unless project
        return [[:private, project.http_url_to_repo]] unless project.public?

        events = [[:add, project.http_url_to_repo]]
        if old_path.present? && old_path != project.full_path
          events << [:moved, { from: repository_url(old_path), to: project.http_url_to_repo }]
        end

        events
      end

      # A namespace move carries its own old path, not each project's, so a
      # project's is its current path with the namespace's prefix swapped
      # back.
      def hierarchy_events(row, projects)
        new_prefix = "#{row.project_path}/"
        old_prefix = "#{row.payload['old_path']}/" if row.namespace_moved?

        Array(row.payload['project_ids']).flat_map do |id|
          project = projects[id]
          next [] unless project

          project_events(project, old_path_under(project.full_path, new_prefix, old_prefix))
        end
      end

      def old_path_under(path, new_prefix, old_prefix)
        return unless old_prefix && path.start_with?(new_prefix)

        old_prefix + path.delete_prefix(new_prefix)
      end

      # Only a repository that was public can have a record to report on. The
      # path is all that is left of it.
      def deleted(row)
        return [] unless row.payload['visibility'] == 'public'

        [[:deleted, repository_url(row.project_path)]]
      end

      def repository_url(path)
        ::Gitlab::RepositoryUrlBuilder.build(path, protocol: :http)
      end

      def request_body(events)
        body = { add: [], analyze: 'metadata', commit: false }
        events.each { |(list, value)| (body[list] ||= []) << value }
        body
      end

      # An empty write with commit set means "commit what earlier requests
      # staged", on both the Python and the Rust handlers.
      def commit(events)
        post('/cloudmap', commit: true, commit_msg: commit_message(events))
      end

      def commit_message(events)
        counts = events.group_by(&:first).transform_values(&:size)
        summary = counts.map { |list, count| "#{count} #{list}" }.join(', ')

        "GitLab: #{summary}"
      end

      # "metadata" re-reads the host's record of a repository without cloning
      # it. Gitlab::HTTP blocks the local network by default, and this posts
      # straight to the unfurl-server container.
      def analyze(events)
        post('/cloudmap/analyze', request_body(events))
      end

      def post(path, body)
        response = ::Gitlab::HTTP.post(
          "#{unfurl_server_url}#{path}",
          query: { auth_project: ::OC::UNFURL_CLOUDMAP_PROJECT },
          headers: { 'Content-Type' => 'application/json' },
          body: ::Gitlab::Json.dump(body),
          allow_local_requests: true
        )
        return true if response.success?

        log_failure(path: path, status: response.code, body: response.body.to_s.truncate(500))
        false
      rescue *::Gitlab::HTTP::HTTP_ERRORS => error
        log_failure(path: path, error_class: error.class.name, error_message: error.message)
        false
      end

      def log_failure(**details)
        ::Gitlab::AppLogger.warn(message: 'cloudmap refresh request failed', **details)
      end

      # In Redis rather than a table: losing it costs a replay of
      # INITIAL_WINDOW, which the server's analyze makes harmless.
      def cursor
        stored = with_redis { |redis| redis.get(CURSOR_KEY) }
        stored ? stored.to_i : ::OC::Projects::CloudmapEvent.cursor_since(INITIAL_WINDOW.ago)
      end

      def cursor=(id)
        with_redis { |redis| redis.set(CURSOR_KEY, id) }
      end

      def with_redis(&block)
        ::Gitlab::Redis::SharedState.with(&block) # rubocop:disable CodeReuse/ActiveRecord -- a Redis pool, not a relation
      end

      def unfurl_server_url
        ::OC::Repositories::UnfurlServer.internal_url
      end
    end
  end
end
