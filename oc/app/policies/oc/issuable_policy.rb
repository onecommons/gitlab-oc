# frozen_string_literal: true

module OC
  # Makes an imported replica read-only.
  #
  # This sits on IssuablePolicy rather than on IssuePolicy and
  # MergeRequestPolicy separately because both inherit from it and both can be
  # replicas. WorkItem is covered too, being a subclass of Issue.
  #
  # Prevented rather than simply not enabled: the abilities below are granted by
  # ProjectPolicy, which IssuablePolicy reaches through `delegate {
  # subject_container }`. DeclarativePolicy merges the runners per ability and a
  # prevent beats an enable unconditionally, whichever policy the enable came
  # from and whatever order the rules were declared in.
  #
  # Modelled on how upstream handles an archived project -- ProjectPolicy's
  # `rule { archived }` prevents this same shape of ability -- but keyed on the
  # record instead of the project, which is what ArchivedAbilities cannot do.
  module IssuablePolicy
    extend ActiveSupport::Concern

    prepended do
      # Not merely "has a replica row": a row also describes an item this
      # instance owns, once one has been transferred to us or matched against a
      # copy we already had. Making one of those read-only would be the worst
      # failure this feature has -- an item nobody imported, that was here all
      # along, quietly becoming uneditable.
      desc 'Issuable is a read-only copy of one held by another instance'
      condition(:oc_read_only, scope: :subject) { !!@subject.oc_replica&.read_only? }

      rule { oc_read_only }.policy do
        # Comments and reactions are prevented, not merely discouraged, because
        # an update to the source is applied by rebuilding: the local record is
        # destroyed and built again. Anything a local user added to it goes with
        # it, silently and with no way to get it back. Refusing the comment is
        # kinder than losing it later.
        prevent :create_note
        prevent :admin_note
        prevent :resolve_note
        prevent :mark_note_as_internal
        prevent :award_emoji

        # Editing the record itself has the same problem and a worse one: the
        # next reconcile compares the source file's blob oid, not our content,
        # so a local edit would not even be noticed as drift. It would simply
        # sit there disagreeing with the instance that owns the item.
        prevent :update_issue
        prevent :admin_issue
        prevent :reopen_issue
        prevent :destroy_issue
        prevent :set_issue_metadata
        prevent :set_issue_crm_contacts
        prevent :set_confidentiality
        prevent :admin_issue_relation
        prevent :admin_issue_link
        prevent :create_timelog

        # An issue is also a work item, and not every work item ability is
        # derived from the issue one: the roles grant admin_work_item and the
        # link abilities directly, so each needs its own prevent.
        prevent :update_work_item
        prevent :admin_work_item
        prevent :delete_work_item
        prevent :set_work_item_metadata
        prevent :admin_work_item_link
        prevent :admin_parent_link

        prevent :update_merge_request
        prevent :admin_merge_request
        prevent :reopen_merge_request
        prevent :destroy_merge_request
        prevent :set_merge_request_metadata

        # A replica is a record of what the source instance decided. Accepting
        # or approving it here would neither merge anything -- the branch it
        # describes belongs to another instance -- nor be visible to anyone
        # deciding the real merge request.
        prevent :accept_merge_request
        prevent :approve_merge_request
        prevent :reset_merge_request_approvals
      end
    end
  end
end
