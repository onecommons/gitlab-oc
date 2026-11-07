# frozen_string_literal: true

module OC
  # Tells whoever pushed sync.yml what it is going to mean, while they are
  # still watching.
  #
  # The refusal on a broken file reaches them already. A file that is *fine*
  # reached nobody, and the mistakes that survive parsing are the expensive
  # ones: a block naming an instance that is not this one, or a push by
  # somebody who cannot authorize an import. Both leave the file looking
  # correct and nothing happening, for ever, with only a server log to say so.
  #
  # What this can say is limited by when it runs, and the limit is worth being
  # clear about. The import has not happened yet -- PostReceiveService enqueues
  # PostReceive, which enqueues ImportWorker, and the run is seconds away in
  # Sidekiq. So this reports what the file *asks for*, never what came of it.
  # Outcomes need somewhere that outlives a push.
  # A module rather than a class: prepend_mod_with prepends this onto the
  # upstream class, and Module#prepend refuses anything but a module.
  module PostReceiveService
    PREFIX = ::OC::WorkItems::SyncFile::PUSH_PREFIX

    def execute
      response = super

      report_sync_file(response)
      report_drafts(response)

      response
    end

    private

    # Nothing here may cost anybody a push. The push has already succeeded by
    # the time this runs -- the ref has moved -- so an exception raised while
    # composing a courtesy message would report a failure that did not happen.
    def report_sync_file(response)
      content = changed_sync_file
      return if content.nil?

      file = ::OC::WorkItems::SyncFile.parse(content)
      warning = warning_for(file)
      text = [summary(file), warning].compact.join("\n")

      if warning
        response.add_alert_message(text)
      else
        response.add_basic_message(text)
      end
    rescue ::OC::WorkItems::SyncFile::Error => error
      # Reachable only when this push created the branch, which the push-time
      # check deliberately leaves alone so that a purge replay can never be
      # refused. This is the one moment that gap is visible to anyone.
      response.add_alert_message(
        "#{PREFIX} #{error.message}\nNothing will be imported until it is fixed.")
    rescue ::StandardError => error
      ::Gitlab::AppLogger.warn(
        message: 'work items sync file could not be reported to the pusher',
        project_id: project&.id, error_class: error.class.name, ::Labkit::Fields::ERROR_MESSAGE => error.message)
    end

    # What the drafts waiting in our inbox will come to, after a push that
    # added or changed one there. Like the sync.yml summary, this is what the
    # run is about to try, not what came of it.
    def report_drafts(response)
      change = sync_branch_change
      return unless change && touches_our_drafts?(change)

      unless project.work_items_sync_enabled?(recording: false)
        response.add_alert_message("#{PREFIX} drafts are not created while work items sync is off for this project")
        return
      end

      lines, refusals = draft_report(change[:newrev])
      response.add_basic_message(lines.join("\n")) if lines.any?
      response.add_alert_message(refusals.join("\n")) if refusals.any?
    rescue ::StandardError => error
      ::Gitlab::AppLogger.warn(
        message: 'work item drafts could not be reported to the pusher',
        project_id: project&.id, error_class: error.class.name, ::Labkit::Fields::ERROR_MESSAGE => error.message)
    end

    def touches_our_drafts?(change)
      return false if ::Gitlab::Git.blank_ref?(change[:oldrev])

      diff = ::Gitlab::Git::DiffTree.new(change[:oldrev], change[:newrev])
      project.repository.find_changed_paths([diff]).any? do |changed|
        !changed.deleted_file? && ::OC::WorkItems::DraftFile.draft_path?(changed.path, instance_uuid)
      end
    end

    def draft_report(sha)
      inbox = "#{instance_uuid}/#{::OC::WorkItems::DraftFile::DIRECTORY}"
      paths = project.repository.tree(sha, inbox).blobs.map(&:path)
        .select { |path| ::OC::WorkItems::DraftFile.draft_path?(path, instance_uuid) }
      keys = paths.index_by { |path| ::OC::WorkItems::DraftFile.key_for(path) }
      used = ::OC::WorkItems::Draft.for_project(project).where(key: keys.keys).pluck(:key) # rubocop:disable CodeReuse/ActiveRecord -- one indexed lookup
      service = ::OC::WorkItems::DraftService.new(project, user)

      refused = {}
      created = (keys.keys - used).sort.select do |key|
        blob = project.repository.blob_at(sha, keys[key])
        blob.load_all_data!
        problem = service.preflight(::OC::WorkItems::DraftFile.parse(blob.data, path: keys[key]))
        refused[key] = problem if problem
        problem.nil?
      end

      lines = []
      lines << "#{PREFIX} #{drafts(created.size)} will be created (#{created.join(', ')})" if created.any?

      lines << "#{PREFIX} #{drafts(used.size)} already created and will be removed (#{used.sort.join(', ')})" if
        used.any?

      [lines, refused.map { |key, problem| "#{PREFIX} draft #{key} cannot be created by you: #{problem}" }]
    end

    def drafts(count)
      "#{count} #{'draft'.pluralize(count)}"
    end

    def summary(file)
      instance = file.instance_for(instance_uuid)
      return "#{PREFIX} sync.yml updated." unless instance

      lines = ["#{PREFIX} sync.yml updated. This instance is '#{instance.name}'."]

      file.imports(instance_uuid).each_value do |pair|
        lines << "  imports #{pair.import} from #{pair.peer_name}"
      end

      file.transfers_from(instance_uuid).each_value do |pair|
        lines << "  transfers #{transferred(pair)} to #{pair.peer_name}"
      end

      lines.join("\n")
    end

    def transferred(pair)
      return 'every issue' if pair.transfers_all?

      "#{pair.transfer.size} issue".pluralize(pair.transfer.size)
    end

    # The two ways a file can be correct and still do nothing.
    def warning_for(file)
      unless file.instance_for(instance_uuid)
        return "It names no instance with this one's uuid (#{instance_uuid}), " \
          'so nothing on this branch will be imported here.'
      end

      return if user && ::Ability.allowed?(user, :destroy_issue, project)

      'Only a push by an Owner or Planner of this project acts on it, so this push changed nothing here.'
    end

    # Read straight off the settings rather than through
    # OC::WorkItems.instance_directory, which raises when there is none.
    def instance_uuid
      ::Gitlab::CurrentSettings.uuid.to_s
    end

    def changed_sync_file
      return unless project && repository&.repo_type&.project?

      change = sync_branch_change
      return unless change

      blob = ::OC::WorkItems::SyncFile.changed_blob(
        project.repository, change[:oldrev], change[:newrev])
      return if blob.nil?
      return if blob.size > ::OC::Gitlab::Checks::SyncFileCheck::MAX_BYTES

      blob.load_all_data!
      blob.data
    end

    def sync_branch_change
      ::Gitlab::ChangesList.new(params[:changes]).find do |change|
        next false if ::Gitlab::Git.blank_ref?(change[:newrev])

        ::Gitlab::Git.branch_name(change[:ref]) == ::OC::WorkItems::SYNC_BRANCH
      end
    end
  end
end
