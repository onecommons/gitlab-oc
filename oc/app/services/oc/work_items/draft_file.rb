# frozen_string_literal: true

module OC
  module WorkItems
    # A new issue written offline: `<uuid>/_incoming/<key>.yml` on the sync
    # branch, created by the installation owning `<uuid>` when it is pushed.
    #
    #   _schema: issue_draft@1             # required
    #   title: <text>                      # required, one line, <= 255
    #   description: <markdown>            # may say #draft:<key>
    #   labels: [<title>, ...]
    #   milestone: <title>
    #   assignees: [<username>, ...]
    #   due_date: <YYYY-MM-DD>
    #   confidential: true | false
    #   type: issue | task | incident      # default issue
    #   .anything: ...                     # yours, ignored
    #
    # Strict like SyncFile::Parser, for the same reason: it is checked at push,
    # while the person who wrote it is there to fix it. Anchors and aliases are
    # refused rather than resolved -- a draft has nothing to share, and refusing
    # them keeps this parser a plain walk of one mapping.
    class DraftFile
      SCHEMA = 'issue_draft@1'
      DIRECTORY = '_incoming'
      EXTENSIONS = %w[.yml .yaml].freeze
      KEY_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
      TYPES = %w[issue task incident].freeze
      KEYS = %w[title description labels milestone assignees due_date confidential type].freeze

      # Bounded on both sides so `#draft:fix-login-2` is not `fix-login`, and a
      # path such as `docs#draft:x` is not a reference.
      REFERENCE = %r{(?<![\w/])#draft:(?<key>[a-z0-9][a-z0-9_-]{0,63})(?![a-z0-9_-])}

      # Code first, so a reference inside it is consumed as code and kept.
      CODE_OR_REFERENCE = /(?<code>#{ReferenceRewriter::CODE})|#{REFERENCE}/

      class Error < StandardError
        attr_reader :path, :line

        def initialize(message, path:, line: nil)
          @path = path
          @line = line

          super(line ? "#{path}:#{line}: #{message}" : "#{path}: #{message}")
        end
      end

      attr_reader :path, :key, :title, :description, :labels, :milestone, :assignees,
        :due_date, :confidential, :type

      class << self
        # Whether path is a draft for the installation owning `directory`: a
        # file directly in its `_incoming/`, with a draft extension. Anything
        # else there (a README, an editor backup) is not a draft.
        def draft_path?(path, directory)
          prefix = "#{directory}/#{DIRECTORY}/"
          return false unless path.start_with?(prefix)

          name = path.delete_prefix(prefix)
          name.exclude?('/') && EXTENSIONS.include?(::File.extname(name))
        end

        def key_for(path)
          ::File.basename(path, ::File.extname(path))
        end

        def parse(yaml, path:)
          new(path, yaml.to_s)
        end

        # text with each `#draft:<key>` outside code replaced by `#<iid>`. Keys
        # with no iid are left as written.
        def rewrite_references(text, iids_by_key)
          return text if text.blank?

          text.gsub(CODE_OR_REFERENCE) do
            match = ::Regexp.last_match
            iid = iids_by_key[match[:key]] unless match[:code]
            iid ? "##{iid}" : match[0]
          end
        end
      end

      def initialize(path, yaml)
        @path = path
        @key = self.class.key_for(path)
        @labels = []
        @assignees = []
        @confidential = false
        @type = 'issue'

        read(yaml)
      end

      def confidential?
        @confidential
      end

      # The `#draft:` keys the description names, outside code.
      def draft_references
        return [] if description.blank?

        description.gsub(ReferenceRewriter::CODE, '').scan(REFERENCE).flatten.uniq
      end

      private

      def read(yaml)
        unless key.match?(KEY_PATTERN)
          fail_at!(nil, "#{key.inspect} is not a valid draft name; use lowercase letters, digits, " \
            '"-" and "_", starting with a letter or digit')
        end

        root = document_root(yaml)
        values = pairs(root)

        schema = values.delete('_schema')
        fail!(root, "no \"_schema\"; expected #{SCHEMA}") unless schema

        fail!(schema.last, "\"_schema\" must be #{SCHEMA}") unless scalar(schema.last, '"_schema"') == SCHEMA

        values.each do |name, (key_node, value_node)|
          fail!(key_node, "unknown key #{name.inspect}; use a \".\" prefix for keys of your own") unless
            KEYS.include?(name)

          read_value(name, value_node)
        end

        fail!(root, 'no "title"') if title.nil?
      end

      def read_value(name, node)
        case name
        when 'title' then @title = read_title(node)
        when 'description' then @description = scalar(node, '"description"', allow_blank: true)
        when 'labels' then @labels = list(node, '"labels"')
        when 'milestone' then @milestone = scalar(node, '"milestone"')
        when 'assignees' then @assignees = list(node, '"assignees"')
        when 'due_date' then @due_date = read_date(node)
        when 'confidential' then @confidential = read_boolean(node, '"confidential"')
        when 'type' then @type = one_of(node, '"type"', TYPES)
        end
      end

      def read_title(node)
        title = scalar(node, '"title"')
        fail!(node, '"title" must be one line') if title.include?("\n")

        fail!(node, "\"title\" is longer than #{::Issuable::TITLE_LENGTH_MAX} characters") if
          title.length > ::Issuable::TITLE_LENGTH_MAX

        title
      end

      def read_date(node)
        ::Date.iso8601(scalar(node, '"due_date"'))
      rescue ::Date::Error
        fail!(node, '"due_date" must be a date written YYYY-MM-DD')
      end

      def read_boolean(node, what)
        value = scalar(node, what)
        return value == 'true' if %w[true false].include?(value) && !node.quoted

        fail!(node, "#{what} must be true or false")
      end

      def document_root(yaml)
        # Psych.parse returns false, not nil, for an empty string.
        document = ::Psych.parse(yaml)
        root = document ? document.root : nil
        fail_at!(nil, 'is empty') if root.nil? || (scalar?(root) && root.value.empty?)
        refuse_anchors!(root)
        fail!(root, 'must be a mapping of keys') unless root.is_a?(::Psych::Nodes::Mapping)

        root
      rescue ::Psych::SyntaxError => error
        fail_at!(error.line, error.problem.presence || 'is not valid YAML')
      end

      def refuse_anchors!(node)
        anchored = node.is_a?(::Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor.present?)
        fail!(node, 'anchors and aliases are not supported in drafts') if anchored

        node.children&.each { |child| refuse_anchors!(child) }
      end

      # {name => [key_node, value_node]}, refusing duplicate keys -- last-wins in
      # every YAML loader, so a duplicate is an edit that appears made and is not.
      def pairs(mapping)
        mapping.children.each_slice(2).with_object({}) do |(key_node, value_node), found|
          fail!(key_node, 'has a key that is not plain text') unless scalar?(key_node)

          name = key_node.value
          next if name.start_with?('.')

          if found.key?(name)
            fail!(key_node, "#{name.inspect} appears twice (already on line #{line_of(found[name].first)})")
          end

          found[name] = [key_node, value_node]
        end
      end

      def scalar(node, what, allow_blank: false)
        fail!(node, "#{what} must be a single value") unless scalar?(node)
        fail!(node, "#{what} is empty") if node.value.blank? && !allow_blank

        node.value
      end

      def list(node, what)
        fail!(node, "#{what} must be a list") unless node.is_a?(::Psych::Nodes::Sequence)

        node.children.map { |child| scalar(child, "each of #{what}") }
      end

      def one_of(node, what, allowed)
        value = scalar(node, what)
        return value if allowed.include?(value)

        fail!(node, "#{what} is #{value.inspect}; it must be one of #{allowed.map(&:inspect).join(', ')}")
      end

      def scalar?(node)
        node.is_a?(::Psych::Nodes::Scalar)
      end

      def line_of(node)
        node.start_line + 1
      end

      def fail!(node, message)
        fail_at!(node && line_of(node), message)
      end

      def fail_at!(line, message)
        raise Error.new(message, path: path, line: line)
      end
    end
  end
end
