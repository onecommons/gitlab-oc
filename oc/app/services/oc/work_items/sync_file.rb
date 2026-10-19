# frozen_string_literal: true

module OC
  module WorkItems
    # What this instance syncs with, declared on the branch itself.
    #
    # Lives at the branch root because it is written by the humans on both
    # sides and owned by neither. Nothing here writes it: the sweep only looks
    # inside our own directory, and a purge replays it verbatim.
    #
    # Importing is opt-in per relationship. An instance named nowhere in this
    # file imports nothing, and an undeclared peer directory is inert. The
    # Owner check on a push says the reading is authorized, not which of the
    # directories on a shared branch were meant to be mirrored.
    #
    # Names are branch-local and for the humans; uuids name the directories, so
    # everything the run asks for comes back keyed by uuid.
    class SyncFile
      PATH = 'sync.yml'
      SCHEMA = 'sync@1'

      # Introduces anything said to somebody pushing. By the time they read it
      # the line already carries git's `remote:` and Gitaly's `GitLab:`, and
      # neither says which part of the system is talking. Not folded into
      # Error's message, which also goes to logs.
      PUSH_PREFIX = 'Work items sync:'

      # Stands for the ghost user in `default_user`.
      #
      # Not `_ghost`: PATH_START_CHAR is `[a-zA-Z0-9_.]`, so that is a username
      # somebody can register. Angle brackets appear in none, and are the only
      # unambiguous form surviving YAML unquoted -- `%ghost` and `@ghost` are
      # parse errors, `:ghost` loads as a Symbol that safe_load refuses.
      GHOST = '<ghost>'

      IMPORT_MODES = %w[all transferred].freeze
      USER_MAPPING_LEVELS = %w[none email username].freeze

      # Carried over from the custom attribute this replaced. A published email
      # is one both sides confirmed, so it is a fact about the accounts rather
      # than a claim by whoever wrote the branch.
      DEFAULT_USER_MAPPING = 'email'

      # Anything wrong with the file as a file. Raised by .parse, which is what
      # the push-time check reports; .load turns it back into silence, because a
      # run cannot ask anybody anything.
      class Error < StandardError
        attr_reader :line

        def initialize(message, line: nil)
          @line = line

          super(line ? "#{PATH}:#{line}: #{message}" : "#{PATH}: #{message}")
        end
      end

      # One direction of one relationship, read from the subject outwards:
      # `import` is us taking their items, `transfer` is us giving them ours.
      # line is kept so a cross-reference failure can point at the declaration.
      Pair = Struct.new(
        :peer_name, :peer_uuid, :import, :user_mapping, :default_user, :transfer, :line,
        keyword_init: true) do
        def imports?
          import.present?
        end

        def imports_all?
          import == 'all'
        end

        # Only what the peer currently transfers to us, rather than their whole
        # directory. The migration mode, and the containment answer for a peer
        # whose items we mostly already have.
        def imports_transferred?
          import == 'transferred'
        end

        def transfers?
          transfer.present?
        end

        def transfers_all?
          transfer == :all
        end

        # The level ImportMembersMapper takes.
        def trust
          (user_mapping || DEFAULT_USER_MAPPING).to_sym
        end

        # Whether unmapped users fall to the ghost, which is both the default
        # and what GHOST asks for explicitly.
        def default_user_ghost?
          default_user.blank? || default_user == GHOST
        end

        # available: the giver's document paths, relative to their directory.
        # `all` is standing intent, so it can only be answered against the
        # branch as it is now. Merge requests are excluded rather than
        # rejected; one named explicitly is refused by the parser.
        def transfer_paths(available)
          case transfer
          when :all then available.select { |path| path.start_with?('issues/') }
          when ::Array then transfer
          else []
          end
        end
      end

      Instance = Struct.new(:name, :uuid, :pairs, :line, keyword_init: true)

      attr_reader :instances

      def initialize(instances = {})
        @instances = instances
      end

      def empty?
        @instances.empty?
      end

      class << self
        def parse(yaml)
          Parser.new(yaml).parse
        end

        # The blob this change leaves at PATH, or nil when the change does not
        # touch the file -- including when it deletes it, which declares
        # nothing rather than being wrong.
        #
        # Shared by the check that refuses a bad file and the message a good
        # one prints back to whoever pushed it, so that the two can never
        # disagree about whether a push touched it.
        def changed_blob(repository, oldrev, newrev)
          blob = repository.blob_at(newrev, PATH)
          return if blob.nil?

          previous = repository.blob_at(oldrev, PATH) unless ::Gitlab::Git.blank_ref?(oldrev)
          return if previous && previous.id == blob.id

          blob
        end

        # For a run, where a file nobody can act on and one declaring nothing
        # amount to the same thing. Reached only by a file that predates the
        # push-time check or arrived by branch creation.
        def load(yaml, project: nil)
          return new if yaml.blank?

          parse(yaml)
        rescue Error => error
          ::Gitlab::AppLogger.warn(
            message: 'work items sync file could not be read; importing nothing',
            project_id: project&.id, ::Labkit::Fields::ERROR_MESSAGE => error.message)

          new
        end
      end

      # The block declaring our own uuid, or nil when this instance is not in
      # the file at all -- silence rather than an error: a branch is shared, and
      # most of the instances named on one are not us.
      def instance_for(uuid)
        return if uuid.blank?

        @instances.each_value.find { |instance| instance.uuid == uuid }
      end

      # {peer uuid => Pair} for the peers we import from.
      def imports(uuid)
        pairs_for(uuid).select { |_peer_uuid, pair| pair.imports? }
      end

      # {peer uuid => Pair} for the peers we give items to.
      def transfers_from(uuid)
        pairs_for(uuid).select { |_peer_uuid, pair| pair.transfers? }
      end

      # {giver uuid => Pair} for the peers giving items to us, read out of
      # *their* blocks: a transfer is declared by the side losing the item, so
      # the receiver never finds it under its own name.
      def transfers_to(uuid)
        us = instance_for(uuid)
        return {} unless us

        @instances.each_value.with_object({}) do |instance, map|
          next if instance.uuid == us.uuid

          pair = instance.pairs[us.name]
          map[instance.uuid] = pair if pair&.transfers?
        end
      end

      private

      def pairs_for(uuid)
        instance = instance_for(uuid)
        return {} unless instance

        instance.pairs.each_value.with_object({}) { |pair, map| map[pair.peer_uuid] = pair }
      end
    end
  end
end
