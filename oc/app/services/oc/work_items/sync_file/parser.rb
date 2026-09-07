# frozen_string_literal: true

module OC
  module WorkItems
    class SyncFile
      # Reads sync.yml, and refuses everything it is not certain about.
      #
      # Strict on purpose, and strict in a way the rest of this feature is not.
      # Elsewhere -- a document that will not build, a peer directory nobody
      # declared -- the answer to something we cannot make sense of is to skip
      # it and carry on, because the alternative is one bad file stopping a run.
      # Here it is the opposite: this file is the instruction, so a part of it
      # we cannot read exactly is not a thing to work around. A typo in a
      # directive that silently meant nothing would be a transfer that never
      # happens and a frozen item nobody can explain.
      #
      # That only pays off because a human is present when it is written. The
      # push-time check runs this and reports what it says, so an error here
      # reaches the person who just made it -- see OC::Checks::SyncFileCheck.
      #
      # Parsed through Psych's AST rather than safe_load for two things the
      # loaded hash cannot give: the line each key sits on, and duplicate keys.
      # A duplicate is last-wins in every YAML loader, which in a file like this
      # means an edit that appears to have been made and was not.
      class Parser
        # The whole of sync@1, which nothing else states in one place:
        #
        #   _schema: sync@1                       # required
        #   _metadata: {...}                      # reserved, unread
        #   .anything: ...                        # yours, at any level
        #
        #   <instance>:                           # must start with a letter
        #     uuid: <string>                      # required
        #     sync:
        #       <peer instance>:
        #         import: all | transferred
        #         user_mapping: none | email | username    # default email
        #         default_user: <username> | <ghost>       # default <ghost>
        #         transfer: all | [issues/42.yml, ...]
        #
        # A top-level key starting with anything else is ignored, so a later
        # schema can put non-declaration data there. A mapping written with no
        # value declares nothing; a scalar left empty is an error.
        #
        # Anchors, aliases and `<<` merge keys work as YAML defines them, which
        # is why a `.` key is worth having: it is where a file with anything to
        # share puts the block it shares.
        #
        # Refused across the whole file: a duplicate key in any mapping, an
        # alias with no anchor, the same anchor defined twice, an instance
        # syncing with itself, a peer the file does not declare, two instances
        # sharing a uuid, an item promised to two instances, a transfer naming
        # a merge request, and a transfer the receiving instance declares no
        # import for.
        #
        # Anything else is refused rather than ignored -- forward compatibility
        # comes from bumping _schema, not from tolerating what this build does
        # not understand.
        INSTANCE_KEYS = %w[uuid sync].freeze
        PAIR_KEYS = %w[import user_mapping default_user transfer].freeze

        TRANSFER_PATH_PATTERN = %r{\Aissues/\d+\.yml\z}

        MERGE_KEY = '<<'
        MAX_MERGE_DEPTH = 8
        MAX_MERGE_EXPANSIONS = 5_000

        def initialize(yaml)
          @yaml = yaml.to_s
        end

        def parse
          root = document_root
          return SyncFile.new if root.nil?

          check_schema!(root)
          instances = read_instances(root)

          check_uuids_unique!(instances)
          resolve_peers!(instances)
          check_transfers_are_imported!(instances)
          check_no_item_given_twice!(instances)

          SyncFile.new(instances)
        end

        private

        # nil for a file with no content at all, which is not an error: an empty
        # control file declares nothing, and so does a missing one.
        def document_root
          document = ::Psych.parse(@yaml)
          return unless document

          @anchors = {}
          @expansions = 0
          collect_anchors(document)

          root = document.root
          return if root.nil?

          root = resolve(root)
          return if null_node?(root)

          fail!(root, 'must be a mapping of instance names') unless mapping?(root)

          root
        rescue ::Psych::SyntaxError => error
          # Psych numbers syntax errors from 1 and nodes from 0; only the latter
          # needs adjusting.
          raise Error.new(error.problem.presence || 'is not valid YAML', line: error.line)
        end

        def check_schema!(root)
          node = value_at(root, '_schema')
          fail!(root, "no \"_schema\"; expected #{SCHEMA}") unless node

          schema = scalar!(resolve(node), '"_schema"')
          return if schema == SCHEMA

          fail!(node, "\"_schema\" has unexpected value #{schema.inspect} " \
            "(expected #{SCHEMA})")
        end

        def read_instances(root)
          instances = {}

          pairs_of(root).each do |key, key_node, value_node|
            next if ignorable?(key)

            if key.start_with?('_')
              check_reserved!(key, key_node, value_node)
              next
            end

            # Digits, punctuation and anything else are left alone rather than
            # refused, so a later schema can put non-declaration data at the top
            # level without this build rejecting the file.
            next unless key.match?(/\A[a-zA-Z]/)

            instances[key] = read_instance(key, key_node, value_node)
          end

          instances
        end

        def check_reserved!(key, key_node, value_node)
          return if key == '_schema'

          if key == '_metadata'
            return if null_node?(value_node) || mapping?(value_node)

            fail!(value_node, '"_metadata" must be a mapping')
          end

          fail!(key_node, "unknown reserved key #{key.inspect}. Keys beginning with \"_\" belong " \
            'to the schema; use a "." prefix for keys of your own')
        end

        def read_instance(name, key_node, node)
          fail!(node, "instance #{name.inspect} must be a mapping") unless mapping?(node)

          uuid = nil
          pairs = {}

          pairs_of(node).each do |key, inner_key_node, value_node|
            next if ignorable?(key)

            case key
            when 'uuid' then uuid = scalar!(value_node, quoted_path(name, 'uuid'))
            when 'sync' then pairs = read_pairs(name, value_node)
            else
              fail!(inner_key_node, "unknown key #{key.inspect} in instance #{name.inspect}; " \
                "an instance takes #{INSTANCE_KEYS.map(&:inspect).join(' and ')}")
            end
          end

          fail!(node, "instance #{name.inspect} has no \"uuid\"") if uuid.blank?

          Instance.new(name: name, uuid: uuid, pairs: pairs, line: line_of(key_node))
        end

        def read_pairs(owner, node)
          return {} if null_node?(node)

          fail!(node, "\"sync\" in #{owner.inspect} must be a mapping of names") unless mapping?(node)

          pairs = {}

          pairs_of(node).each do |peer, key_node, value_node|
            next if ignorable?(peer)

            fail!(key_node, "#{owner.inspect} cannot sync with itself") if peer == owner

            pairs[peer] = read_pair(owner, peer, key_node, value_node)
          end

          pairs
        end

        def read_pair(owner, peer, key_node, node)
          pair = Pair.new(peer_name: peer, line: line_of(key_node))
          return pair if null_node?(node)

          fail!(node, "#{pair_path(owner, peer)} must be a mapping") unless mapping?(node)

          pairs_of(node).each do |key, inner_key_node, value_node|
            next if ignorable?(key)

            case key
            when 'import'
              pair.import = one_of!(value_node, pair_path(owner, peer, 'import'), IMPORT_MODES)
            when 'user_mapping'
              pair.user_mapping =
                one_of!(value_node, pair_path(owner, peer, 'user_mapping'), USER_MAPPING_LEVELS)
            when 'default_user'
              pair.default_user = read_default_user(owner, peer, value_node)
            when 'transfer'
              pair.transfer = read_transfer(owner, peer, value_node)
            else
              fail!(inner_key_node, "unknown key #{key.inspect} in #{pair_path(owner, peer)}; " \
                "a peer instance section takes " \
                "#{PAIR_KEYS.map(&:inspect).join(', ')}")
            end
          end

          pair
        end

        # Whether the named account exists, and whether it is a member of the
        # receiving project, is deliberately not checked here: that is database
        # state on one side, which a push to either instance cannot see and
        # which can become true later. The run waits for it. Only the shape is
        # decidable from the file, so only the shape is decided here.
        def read_default_user(owner, peer, node)
          value = scalar!(node, pair_path(owner, peer, 'default_user'))
          return value if value == GHOST

          if value.start_with?('<')
            fail!(node, "unknown \"default_user\" keyword #{value.inspect} in " \
              "#{pair_path(owner, peer)}; the only one is #{GHOST}")
          end

          unless ::Gitlab::PathRegex.namespace_format_regex.match?(value)
            fail!(node, "\"default_user\" #{value.inspect} in #{pair_path(owner, peer)} is not a " \
              "valid username (use #{GHOST} for the ghost user)")
          end

          value
        end

        def read_transfer(owner, peer, node)
          if scalar?(node)
            return :all if node.value == 'all'

            fail!(node, "\"transfer\" in #{pair_path(owner, peer)} must be `all` or a list of " \
              "paths, not #{node.value.inspect}")
          end

          unless node.is_a?(::Psych::Nodes::Sequence)
            fail!(node, "\"transfer\" in #{pair_path(owner, peer)} must be `all` or a list of paths")
          end

          node.children.map { |child| read_transfer_path(owner, peer, resolve(child)) }
        end

        def read_transfer_path(owner, peer, node)
          path = scalar!(node, "\"transfer\" entry in #{pair_path(owner, peer)}")

          if path.start_with?('merge_requests/')
            fail!(node, "#{pair_path(owner, peer)} transfers #{path}, but merge requests cannot " \
              'be transferred yet')
          end

          return path if path.match?(TRANSFER_PATH_PATTERN)

          fail!(node, "#{pair_path(owner, peer)} transfers #{path.inspect}, which is not a path " \
            "like issues/42.yml relative to #{owner}'s own directory")
        end

        def check_uuids_unique!(instances)
          seen = {}

          instances.each_value do |instance|
            other = seen[instance.uuid]

            if other
              fail_at!(instance.line,
                "#{instance.name.inspect} declares the same \"uuid\" as #{other.name.inspect}")
            end

            seen[instance.uuid] = instance
          end
        end

        # Binds each pair's peer name to that instance's uuid, which is also
        # where a name nobody declared is caught. Done after every block is read
        # so that the file need not be written in dependency order.
        def resolve_peers!(instances)
          instances.each_value do |instance|
            instance.pairs.each_value do |pair|
              peer = instances[pair.peer_name]

              unless peer
                fail_at!(pair.line, "#{instance.name.inspect} syncs with " \
                  "#{pair.peer_name.inspect}, which this file does not declare")
              end

              pair.peer_uuid = peer.uuid
            end
          end
        end

        # A transfer the receiving side has not agreed to import can never
        # complete: the giver freezes its items and the receiver never builds
        # them, so they are read-only on one instance and absent from the other
        # for as long as the file says so. Refusing the push is the only moment
        # anybody can be told.
        #
        # The giver needs no declaration of its own -- a block holding only
        # `transfer` is complete, because a giver reads the receiver's directory
        # in demote-only mode once it holds surrendered rows naming it.
        def check_transfers_are_imported!(instances)
          instances.each_value do |instance|
            instance.pairs.each_value do |pair|
              next unless pair.transfers?

              back = instances.fetch(pair.peer_name).pairs[instance.name]
              next if back&.imports?

              fail_at!(pair.line,
                "#{instance.name.inspect} transfers to #{pair.peer_name.inspect}, but " \
                  "#{pair.peer_name.inspect} declares no \"import\" from #{instance.name.inspect}")
            end
          end
        end

        # An item can be given to one instance only, and this file is where that
        # is decided. Two claims on the same item are not something to settle by
        # precedence at run time: whichever way it went would be a guess at what
        # the person writing this meant.
        def check_no_item_given_twice!(instances)
          instances.each_value do |instance|
            transferring = instance.pairs.each_value.select(&:transfers?)
            everything = transferring.select(&:transfers_all?)

            if everything.size > 1
              fail_at!(everything.last.line,
                "#{instance.name.inspect} transfers everything to both " \
                  "#{everything.first.peer_name.inspect} and #{everything.last.peer_name.inspect}")
            end

            check_listed_items_once!(instance, transferring, everything.first)
          end
        end

        def check_listed_items_once!(instance, transferring, everything)
          seen = {}

          transferring.reject(&:transfers_all?).each do |pair|
            if everything
              fail_at!(pair.line,
                "#{instance.name.inspect} transfers everything to " \
                  "#{everything.peer_name.inspect} and also names items for " \
                  "#{pair.peer_name.inspect}")
            end

            pair.transfer.each do |path|
              other = seen[path]

              if other
                fail_at!(pair.line, "#{instance.name.inspect} transfers #{path} to both " \
                  "#{other.inspect} and #{pair.peer_name.inspect}")
              end

              seen[path] = pair.peer_name
            end
          end
        end

        # Keys beginning with a dot are the reader's own: never interpreted,
        # never refused, at any level. YAML comments cannot serve here because
        # nothing that rewrites a file preserves them, and a file two teams edit
        # needs somewhere to say why an entry is there.
        def ignorable?(key)
          key.start_with?('.')
        end

        # Every part of a path is either a key name or an instance name, so the
        # whole of it is quoted rather than each piece.
        def quoted_path(*parts)
          parts.join('/').inspect
        end

        def pair_path(owner, peer, key = nil)
          quoted_path(*[owner, 'sync', peer, key].compact)
        end

        # A key written out here wins over one merged in, and an earlier merge
        # source over a later -- YAML's own rule.
        #
        # Two caps, because merging is the one thing here that can cost more
        # than the file is long. Depth stops an anchor that merges itself. The
        # expansion budget stops the cheaper attack: an alias may be repeated,
        # so eight levels of ten repeats each is 10^8 expansions of a file well
        # under MAX_BYTES, and this runs on the push path.
        def pairs_of(node, depth = 0)
          fail!(node, "\"#{MERGE_KEY}\" is nested too deeply") if depth > MAX_MERGE_DEPTH

          @expansions += 1
          fail!(node, "\"#{MERGE_KEY}\" expands to too much") if @expansions > MAX_MERGE_EXPANSIONS

          pairs = []
          merged = []
          lines = {}

          node.children.each_slice(2) do |key_node, value_node|
            key = scalar_key!(key_node)
            first = lines[key]

            if first
              fail!(key_node,
                "#{key.inspect} appears twice in the same mapping (already on line #{first})")
            end

            lines[key] = line_of(key_node)

            if key == MERGE_KEY
              merge_sources(value_node).each { |source| merged.concat(pairs_of(source, depth + 1)) }
            else
              pairs << [key, key_node, resolve(value_node)]
            end
          end

          merged.each do |pair|
            next if lines.key?(pair.first)

            lines[pair.first] = line_of(pair[1])
            pairs << pair
          end

          pairs
        end

        def merge_sources(node)
          nodes = node.is_a?(::Psych::Nodes::Sequence) ? node.children : [node]

          nodes.map do |child|
            source = resolve(child)
            fail!(child, "\"#{MERGE_KEY}\" takes a mapping, or a list of them") unless
              mapping?(source)

            source
          end
        end

        # An anchor can hold anything, so everything that consumes a value node
        # takes the anchored node in its place before asking what it is.
        def resolve(node)
          return node unless node.is_a?(::Psych::Nodes::Alias)

          target = @anchors[node.anchor]
          fail!(node, "no anchor named \"&#{node.anchor}\"") unless target

          target
        end

        # Collected from the whole document before anything is read, so that an
        # anchor on a `.` key is found: that is where a file with anything to
        # share will put it, and nothing descends into those.
        def collect_anchors(node)
          anchor = node.anchor if node.respond_to?(:anchor) && !node.is_a?(::Psych::Nodes::Alias)

          if anchor.present?
            fail!(node, "anchor \"&#{anchor}\" is defined twice") if @anchors.key?(anchor)

            @anchors[anchor] = node
          end

          node.children&.each { |child| collect_anchors(child) }
        end

        def value_at(mapping, wanted)
          found = mapping.children.each_slice(2).find do |key_node, _value_node|
            scalar?(key_node) && key_node.value == wanted
          end

          found&.last
        end

        def scalar_key!(node)
          fail!(node, 'has a key that is not plain text') unless scalar?(node)

          node.value
        end

        def scalar!(node, what)
          fail!(node, "#{what} must be a single value") unless scalar?(node)
          fail!(node, "#{what} is empty") if node.value.blank?

          node.value
        end

        def one_of!(node, what, allowed)
          value = scalar!(node, what)
          return value if allowed.include?(value)

          fail!(node, "#{what} is #{value.inspect}; it must be one of " \
            "#{allowed.map(&:inspect).join(', ')}")
        end

        def mapping?(node)
          node.is_a?(::Psych::Nodes::Mapping)
        end

        def scalar?(node)
          node.is_a?(::Psych::Nodes::Scalar)
        end

        # A key written with no value at all. Distinguished from an empty string
        # by the quoting, because `sync:` meaning "nothing here" and `uuid: ""`
        # meaning "the empty uuid" are different mistakes.
        def null_node?(node)
          scalar?(node) && node.value.empty? && !node.quoted
        end

        def line_of(node)
          node.start_line + 1
        end

        def fail!(node, message)
          fail_at!(node && line_of(node), message)
        end

        def fail_at!(line, message)
          raise Error.new(message, line: line)
        end
      end
    end
  end
end
