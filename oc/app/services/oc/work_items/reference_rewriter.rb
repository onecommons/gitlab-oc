# frozen_string_literal: true

module OC
  module WorkItems
    # Rewrites references in imported text so they mean here what they meant on
    # the instance that wrote them.
    #
    # This is not a nicety. `#7` in a document from another instance means
    # *their* issue 7, and left alone it resolves to *ours* -- a different item,
    # with a different title, and nothing about it looks wrong. Same for
    # `@jane`, which resolves to whichever local account happens to hold that
    # name and records her as mentioned in an item that is not about her.
    #
    # (It does not email her. Mention notifications come from
    # Notes::CreateService by way of NewNoteWorker, and an import goes nowhere
    # near either -- records are built by RelationFactory and saved directly.
    # What does happen is store_mentions!, reached from CacheMarkdownField on
    # save, which writes the mention index against a local user id.)
    #
    # What each kind of reference becomes:
    #
    # * `#7` / `!7` -- the local number of the replica, which is usually but
    #   not always the same number; otherwise a link to the source item.
    # * `group/project#7` -- the local number when it names the source's own
    #   project, since that is the same thing said the long way; otherwise a
    #   link to the source, because a path that resolves here is a different
    #   project that merely shares a name.
    # * `@jane` -- a live mention when identity trust matched her to a local
    #   account, using the local name, which may differ. Otherwise a link to
    #   her profile on the source instance: it names who was meant without
    #   claiming a local account is that person.
    class ReferenceRewriter
      # Code is skipped wholesale. `#1` inside a fenced block or a code span is
      # not a reference, and rewriting it would corrupt content that is often
      # the very thing being discussed.
      #
      # Order matters twice: code has to win over everything, and the
      # path-qualified form has to be tried before the bare one.
      SEGMENT = %r{
        (?<code>
          ^[ \t]{0,3}(?<fence>```|~~~)[\s\S]*?^[ \t]{0,3}\k<fence>[^\n]*$
          |
          `[^`\n]+`
        )
        |
        (?<xref>
          (?<![\w/])
          (?<xpath>[a-zA-Z0-9_.][a-zA-Z0-9_.-]*(?:/[a-zA-Z0-9_.][a-zA-Z0-9_.-]*)+)
          (?<xsigil>[\#!])(?<xiid>\d+)(?!\d)
        )
        |
        (?<issue>(?<![\w/])\#(?<issue_iid>\d+)(?!\d))
        |
        (?<merge_request>(?<![\w/])!(?<mr_iid>\d+)(?!\d))
        |
        (?<mention>(?<![\w/])@(?<username>[a-zA-Z0-9_](?:[a-zA-Z0-9_.-]*[a-zA-Z0-9_])?))
      }xm

      PATH_SUFFIX = %r{/-/(?:issues|merge_requests)/\d+\z}

      RELATION_FOR = { '#' => :issues, '!' => :merge_requests }.freeze

      # source_web_url: the imported item's own URL on the source instance.
      # source_origin:  the source instance's base URL, without any project
      #                 path. Needed for anything that is not in the same
      #                 project -- a user profile, another project's item --
      #                 and it cannot be parsed out of a URL, because an
      #                 instance may live under a relative root. ImportService
      #                 subtracts the known project path instead.
      # source_project_path: the source project's full path, so a reference
      #                 that names it can be recognised as meaning "here".
      # usernames:      {source username => local username}, local nil when
      #                 identity trust did not match them.
      def initialize(
        project,
        source_instance_uuid:,
        source_web_url: nil,
        source_origin: nil,
        source_project_path: nil,
        usernames: {})
        @project = project
        @source_instance_uuid = source_instance_uuid
        @source_base = source_web_url&.sub(PATH_SUFFIX, '')
        @source_origin = source_origin
        @source_project_path = source_project_path
        @usernames = usernames || {}
        @unresolved = []
      end

      # Source iids this text referred to that have no local record yet. The
      # caller collects them so a later run can rebuild this item once they
      # arrive -- nothing in the source file will change to prompt it.
      attr_reader :unresolved

      def rewrite(text)
        return text if text.blank?

        text.gsub(SEGMENT) { replace(Regexp.last_match) }
      end

      private

      def replace(match)
        return match[0] if match[:code]
        return cross_project(match) if match[:xref]
        return replacement(:issues, match[:issue_iid], match[0]) if match[:issue]
        return replacement(:merge_requests, match[:mr_iid], match[0]) if match[:merge_request]

        mention(match[:username], match[0])
      end

      # A path naming the source's own project says the same thing a bare
      # reference does. Any other path is a project on the source instance --
      # and a local project that happens to share the path is a different
      # project, so resolving it here would be the exact mistake this class
      # exists to prevent.
      def cross_project(match)
        relation = RELATION_FOR.fetch(match[:xsigil])

        return replacement(relation, match[:xiid], match[0]) if match[:xpath] == @source_project_path

        link(match[0], "#{@source_origin}/#{match[:xpath]}/-/#{relation}/#{match[:xiid]}")
      end

      def mention(username, original)
        local = @usernames[username]
        return "@#{local}" if local

        # Every mention that is not a matched local account, including one this
        # instance has never heard of -- a name only appears in ids.yml when it
        # authored or was assigned something, so most mentions in prose will
        # not be there at all.
        link(original, "#{@source_origin}/#{username}")
      end

      def replacement(relation, source_iid, original)
        replica = replica_for(relation, source_iid)
        local = replica&.work_item

        return "#{prefix(relation)}#{local.iid}" if local

        @unresolved << source_iid.to_i
        link(original, replica&.source_web_url || same_project_url(relation, source_iid))
      end

      # Looked up by path, not by source_iid: the unique index is on
      # (project_id, source_instance_uuid, source_path), and an iid is one
      # string away from being a path. There is no index on source_iid.
      #
      # rubocop: disable CodeReuse/ActiveRecord -- the query belongs to the sync and has no finder
      def replica_for(relation, source_iid)
        OC::WorkItems::ReplicatedWorkItem.find_by(
          project_id: @project.id,
          source_instance_uuid: @source_instance_uuid,
          source_path: "#{@source_instance_uuid}/#{relation}/#{source_iid}.yml")
      end
      # rubocop: enable CodeReuse/ActiveRecord

      def prefix(relation)
        relation == :issues ? '#' : '!'
      end

      def same_project_url(relation, source_iid)
        "#{@source_base}/-/#{relation}/#{source_iid}" if @source_base
      end

      # With no URL to point at, the reference is left exactly as it was. A
      # link to nowhere is worse than a reference a reader can at least ask
      # about, and a half-built URL is worse than both.
      def link(original, url)
        url.present? && !url.start_with?('/') ? "[#{original}](#{url})" : original
      end
    end
  end
end
