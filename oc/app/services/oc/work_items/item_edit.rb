# frozen_string_literal: true

module OC
  module WorkItems
    # An offline edit to one of this installation's own issue files: the file
    # before and after a push, reduced to the changes this installation can
    # apply. Reads only; whether the changes still apply and who may make them
    # is ItemEditCheck's business.
    #
    # Anything outside EDITABLE that changed refuses the edit rather than being
    # dropped: an edit that is partly ignored is worse than none.
    class ItemEdit
      EDITABLE = %w[title description state confidential due_date label_links milestone notes].freeze
      STATES = %w[opened closed].freeze

      # The file has no note ids. Within one issue a comment is its author,
      # its creation time and its discussion.
      NOTE_IDENTITY = %w[author_id created_at discussion_id].freeze

      Error = Class.new(DraftFile::Error)

      SCALAR_RULES = {
        'title' => [->(value) { value.is_a?(String) && value.present? && value.exclude?("\n") },
          '"title" must be one line of text'],
        'description' => [->(value) { value.nil? || value.is_a?(String) }, '"description" must be text'],
        'state' => [->(value) { STATES.include?(value) }, "\"state\" must be one of #{STATES.join(', ')}"],
        'confidential' => [->(value) { [true, false].include?(value) }, '"confidential" must be true or false'],
        'due_date' => [->(value) { value.nil? || date?(value) }, '"due_date" must be a date written YYYY-MM-DD']
      }.freeze

      NewNote = Struct.new(:note, keyword_init: true)
      EditedNote = Struct.new(:author_id, :created_at, :discussion_id, :old_note, :note, keyword_init: true)

      # {field => [before, after]} for each changed field. Labels and the
      # milestone are by title: labels as sorted title lists, the milestone as
      # a title or nil.
      attr_reader :path, :iid, :fields, :new_notes, :edited_notes

      class << self
        # Whether path is one of the issue files the installation owning
        # `directory` writes.
        def item_path?(path, directory)
          parsed = RecordSerializer.parse_path(path)
          parsed.present? && parsed[:directory] == directory && parsed[:relation] == :issues
        end

        def iid_for(path)
          RecordSerializer.parse_path(path)&.dig(:iid)
        end

        # Our own issue files a push from oldrev to newrev changed, as
        # [old path, new path]. A file renamed is one edit: git reports it as
        # one deleted and one added under the same number, and the sync keeps
        # the new name. Otherwise adding or deleting a file is not an edit;
        # like every other file the installation writes, it is ignored and put
        # right by the sync.
        def changed_paths(repository, oldrev, newrev)
          diff = ::Gitlab::Git::DiffTree.new(oldrev, newrev)
          directory = OC::WorkItems.instance_directory
          edited = []
          added = {}
          deleted = {}

          repository.find_changed_paths([diff]).each do |changed|
            next unless item_path?(changed.path, directory)

            if changed.new_file?
              added[iid_for(changed.path)] = changed.path
            elsif changed.deleted_file?
              deleted[iid_for(changed.path)] = changed.path
            else
              edited << [changed.renamed_file? ? changed.old_path : changed.path, changed.path]
            end
          end

          edited + (deleted.keys & added.keys).map { |iid| [deleted[iid], added[iid]] }
        end

        def diff(path:, old_yaml:, new_yaml:)
          new(path, old_yaml, new_yaml)
        end

        # A key of #statuses, for a message.
        def describe(key)
          key.is_a?(String) ? key.inspect : "the comment of #{key.created_at}"
        end

        # The editable fields of a serialized issue, compared the way #fields
        # compares them; comments as {identity => text}.
        def values(yaml)
          document = ::Psych.safe_load(yaml.to_s, permitted_classes: [::Date, ::Time], aliases: false) || {}
          due_date = document['due_date']

          document.slice('title', 'description', 'state', 'confidential').merge(
            'due_date' => due_date.is_a?(String) ? ::Date.iso8601(due_date) : due_date,
            'label_links' => Array(document['label_links']).filter_map { |link| link.dig('label', 'title') }.sort,
            'milestone' => document['milestone'].is_a?(Hash) ? document['milestone']['title'] : nil,
            'notes' => Array(document['notes']).to_h { |entry| [entry.values_at(*NOTE_IDENTITY), entry['note']] }
          )
        end
      end

      def initialize(path, old_yaml, new_yaml)
        @path = path
        @iid = self.class.iid_for(path)
        @fields = {}
        @new_notes = []
        @edited_notes = []

        before = load(old_yaml)
        after = load(new_yaml)
        compare(before, after)
      end

      def empty?
        fields.empty? && new_notes.empty? && edited_notes.empty?
      end

      # How each change stands against the item now, given a fresh
      # serialization of it: :pending while it still has the value the push
      # started from, :done once it has the pushed value, :conflict if it has
      # anything else. Keyed by field name, EditedNote or NewNote.
      #
      # Labels and new comments never conflict. Labels are the labels added
      # and removed, each on its own, so a label someone else added on the web
      # does not stand in the way. A new comment is :done once `author_id` has
      # a comment with its text that the push did not start from.
      def statuses(current_yaml, author_id: nil)
        current = self.class.values(current_yaml)

        statuses = fields.to_h do |field, (old_value, new_value)|
          next [field, label_status(current[field], old_value, new_value)] if field == 'label_links'

          [field, status(current[field], old_value, new_value)]
        end

        edited_notes.each do |note|
          identity = [note.author_id, note.created_at, note.discussion_id]
          statuses[note] = status(current['notes'][identity], note.old_note, note.note)
        end

        posted = current['notes'].filter_map do |identity, text|
          text if identity.first == author_id && @old_note_identities.exclude?(identity)
        end

        new_notes.each do |note|
          index = posted.index(note.note)
          statuses[note] = index ? :done : :pending
          posted.delete_at(index) if index
        end

        statuses
      end

      private

      def label_status(current, old_titles, new_titles)
        added = new_titles - old_titles
        removed = old_titles - new_titles
        done = (added - current).empty? && !current.intersect?(removed)

        done ? :done : :pending
      end

      def status(current, old_value, new_value)
        return :done if current == new_value
        return :pending if current == old_value

        :conflict
      end

      def compare(before, after)
        (before.keys | after.keys).each do |key|
          next if EDITABLE.include?(key) || before[key] == after[key]

          fail!("#{key.inspect} cannot be changed offline")
        end

        compare_scalars(before, after)
        compare_labels(before['label_links'], after['label_links'])
        compare_milestone(before['milestone'], after['milestone'])
        compare_notes(Array(before['notes']), Array(after['notes']))
      end

      def compare_scalars(before, after)
        %w[title description state confidential due_date].each do |key|
          old_value = before[key]
          new_value = after[key]
          next if old_value == new_value

          validate_scalar!(key, new_value)
          old_value, new_value = [old_value, new_value].map { |value| to_date(value) } if key == 'due_date'
          next if old_value == new_value

          @fields[key] = [old_value, new_value]
        end
      end

      def validate_scalar!(key, value)
        valid, message = SCALAR_RULES.fetch(key)
        fail!(message) unless instance_exec(value, &valid)

        fail!("\"title\" is longer than #{::Issuable::TITLE_LENGTH_MAX} characters") if
          key == 'title' && value.length > ::Issuable::TITLE_LENGTH_MAX
      end

      def date?(value)
        value.is_a?(::Date) || (value.is_a?(String) && ::Date.iso8601(value))
      rescue ::Date::Error
        false
      end

      def to_date(value)
        value.is_a?(String) ? ::Date.iso8601(value) : value
      end

      # A label kept must be left as it is; a label added needs only its title.
      def compare_labels(before, after)
        old_labels = labels_by_title(before, 'was')
        new_labels = labels_by_title(after, 'is')

        (old_labels.keys & new_labels.keys).each do |title|
          fail!("label #{title.inspect} can only be added or removed, not changed") if
            old_labels[title] != new_labels[title]
        end

        return if old_labels.keys.sort == new_labels.keys.sort

        @fields['label_links'] = [old_labels.keys.sort, new_labels.keys.sort]
      end

      def labels_by_title(links, tense)
        fail!('"label_links" must be a list') unless links.nil? || links.is_a?(Array)

        Array(links).each_with_object({}) do |link, found|
          title = link.is_a?(Hash) && link['label'].is_a?(Hash) ? link['label']['title'] : nil
          fail!("each of \"label_links\" needs label: { title: ... }") unless title.is_a?(String) && title.present?
          fail!("label #{title.inspect} #{tense} listed twice") if found.key?(title)

          found[title] = link
        end
      end

      # Changing the milestone means naming another one; keeping it means
      # leaving it as it is.
      def compare_milestone(before, after)
        old_title = milestone_title(before)
        new_title = milestone_title(after)

        if old_title == new_title
          fail!('the milestone can only be replaced or removed, not changed') if before != after
          return
        end

        @fields['milestone'] = [old_title, new_title]
      end

      def milestone_title(milestone)
        return if milestone.nil?

        title = milestone.is_a?(Hash) ? milestone['title'] : nil
        fail!('"milestone" needs a title: { title: ... }') unless title.is_a?(String) && title.present?

        title
      end

      def compare_notes(before, after)
        old_by_identity = before.group_by { |entry| note_identity(entry) }
        @old_note_identities = old_by_identity.keys.to_set

        after.each do |entry|
          fail!('each of "notes" must be a mapping') unless entry.is_a?(Hash)

          matches = old_by_identity[note_identity(entry)]
          if matches.nil?
            add_new_note(entry)
          elsif matches.exclude?(entry)
            add_edited_note(matches, entry)
          end
        end

        removed = before.reject { |entry| identity_in?(after, entry) }
        fail!("comments cannot be deleted offline (#{describe(removed.first)})") if removed.any?
      end

      def add_new_note(entry)
        fail!('a new comment may only have "note"') unless entry.keys == ['note']

        @new_notes << NewNote.new(note: note_text(entry))
      end

      def add_edited_note(matches, entry)
        fail!("#{describe(entry)} matches more than one comment, so it cannot be changed") if matches.size > 1

        original = matches.first
        unless original.except('note') == entry.except('note')
          fail!("only the text of #{describe(entry)} can be changed")
        end

        fail!("#{describe(entry)} is a system note and cannot be changed") if original['system']

        @edited_notes << EditedNote.new(
          **NOTE_IDENTITY.index_with { |key| original[key] }.symbolize_keys,
          old_note: original['note'], note: note_text(entry))
      end

      def note_text(entry)
        text = entry['note']
        fail!('a comment needs "note" text') unless text.is_a?(String) && text.present?

        text
      end

      def note_identity(entry)
        entry.is_a?(Hash) ? entry.values_at(*NOTE_IDENTITY) : nil
      end

      def identity_in?(entries, entry)
        identity = note_identity(entry)
        entries.any? { |other| note_identity(other) == identity }
      end

      def describe(entry)
        "the comment of #{entry['created_at']}"
      end

      # Plain data only, and no duplicate top-level keys: every loader keeps the
      # last one, so a duplicate is an edit that appears made and is not.
      def load(yaml)
        document = ::Psych.parse(yaml.to_s)
        root = document ? document.root : nil
        fail!('must be a mapping of keys') unless root.is_a?(::Psych::Nodes::Mapping)

        keys = root.children.each_slice(2).map { |key, _| key.respond_to?(:value) ? key.value : nil }
        duplicate = keys.detect { |key| keys.count(key) > 1 }
        fail!("#{duplicate.inspect} appears twice") if duplicate

        ::Psych.safe_load(yaml, permitted_classes: [::Date, ::Time], aliases: false)
      rescue ::Psych::SyntaxError => error
        raise Error.new(error.problem.presence || 'is not valid YAML', path: path, line: error.line)
      rescue ::Psych::AliasesNotEnabled, ::Psych::DisallowedClass => error
        fail!(error.message)
      end

      def fail!(message)
        raise Error.new(message, path: path)
      end
    end
  end
end
