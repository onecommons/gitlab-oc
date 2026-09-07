# frozen_string_literal: true

module OC
  module Issue
    extend ActiveSupport::Concern

    prepended do
      # Present when this issue is a read-only copy of one on another instance.
      # OC::IssuablePolicy reads it on every permission check, so it is backed
      # by a unique index and wants preloading on list pages.
      #
      # No `dependent:` on purpose. The foreign key nullifies, which leaves the
      # row -- and the source_blob_oid the reconcile compares against -- in
      # place when a rebuild destroys and recreates the record.
      has_one :oc_replica, class_name: 'OC::WorkItems::ReplicatedWorkItem', inverse_of: :issue
    end
  end
end
