# frozen_string_literal: true

module OC
  module WorkItems
    # Answers "who, locally, is user 12 on the instance that wrote this file?"
    #
    # Stands in for Gitlab::ImportExport::MembersMapper, which
    # Base::RelationFactory expects but which we must not use. Its
    # ensure_default_member! calls `importable.members.destroy_all` and re-adds
    # the importing user at the highest access level -- so importing a peer's
    # issues would wipe the receiving project's membership. That is a
    # reasonable thing for a whole-project import to do and a catastrophic one
    # here.
    #
    # The interface RelationFactory actually uses is small: `map`, which must
    # answer with a local user id for any source id, and `include?`, which
    # decides whether a note gets a byline naming its original author.
    #
    # Two further differences from upstream, both deliberate:
    #
    # * Unmapped users become the ghost user, or whoever the relationship names
    #   as its default_user -- never the importing user. Upstream attributes
    #   everything it cannot place to whoever ran the import, which here would
    #   make every replica look like it was written by whoever pushed the
    #   branch.
    # * Mapping matches a verified public_email before a username, and how far
    #   it goes is declared per relationship in sync.yml. Upstream gates this on
    #   the importer being an admin; our gate is project ownership, which is a
    #   lower bar, so the check on the identity itself has to be higher.
    #   Usernames are mutable and can be re-registered after a rename, which is
    #   why they are the fallback rather than the key.
    class ImportMembersMapper
      # trust: how far to go in deciding that one of their users is one of
      # ours -- :none, :email, or :username. See SyncFile for why it is one
      # value rather than a flag each.
      #
      # default_user: who everyone unmapped becomes, or nil for ghost_user.
      # Declared per relationship in sync.yml, and checked there for being a
      # local account this project can be asked to attribute work to.
      def initialize(identities: {}, trust: :none, default_user: nil, ghost_user: nil)
        @identities = (identities || {}).transform_keys(&:to_i)
        @trust = trust&.to_sym || :none
        @default_user = default_user
        @ghost_user = ghost_user
      end

      # A Hash rather than a method because RelationFactory subscripts it
      # directly (`@members_mapper.map[old_id]`), and it must answer for source
      # ids it has never heard of.
      def map
        @map ||= ::Hash.new(default_user_id).merge(resolved)
      end

      def include?(old_user_id)
        resolved.key?(old_user_id.to_i)
      end

      # Everyone the mapping could not place: the author of an item written by
      # somebody with no account here, and equally its assignees, its closer and
      # anyone who reacted to it.
      #
      # The ghost unless a relationship names somebody. Attributing to the
      # ghost is the honest answer -- upstream's importer attributes what it
      # cannot place to whoever ran the import, which here would make every
      # replica look like it was written by whoever pushed the branch -- but it
      # is not always the useful one, and an instance draining into another
      # would rather have its unmatched people land on a service account that
      # can be assigned and mentioned.
      def default_user_id
        @default_user_id ||= (@default_user || @ghost_user).id
      end

      # {local id => source id} for the users actually placed, which is the one
      # fact about an import that cannot be recovered afterwards: both
      # instances publish an ids.yml, but neither records that their user 12
      # and our user 500 are the same person. Inverted from `resolved` because
      # a reader starts from what they can see locally.
      #
      # Users that fell through to the ghost are left out -- "everyone
      # unmatched is the same local id" is not a correspondence.
      def local_to_source
        resolved.invert
      end

      private

      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def resolved
        @resolved ||=
          if @trust == :none
            {}
          else
            @identities.filter_map do |source_id, entry|
              user = find_user(entry)
              [source_id, user.id] if user
            end.to_h
          end
      end

      # public_email is the verified path: GitLab only lets a user publish an
      # address it has confirmed belongs to them, so a match means the two
      # accounts proved ownership of the same mailbox. A username match proves
      # only that two instances use the same string.
      def find_user(entry)
        entry = entry.stringify_keys if entry.respond_to?(:stringify_keys)
        return unless entry.is_a?(::Hash)

        email = entry['public_email'].presence
        by_email = email && ::User.find_by(public_email: email)
        return by_email if by_email

        # Only at the level that asked for it. Not a rare tiebreak either:
        # ids.yml carries a public email only for people who published one, so
        # for everyone else this is the only path there is.
        return unless @trust == :username

        username = entry['username'].presence
        username && ::User.find_by_username(username)
      end
      # rubocop: enable CodeReuse/ActiveRecord
    end
  end
end
