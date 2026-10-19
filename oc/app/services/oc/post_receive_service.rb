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
