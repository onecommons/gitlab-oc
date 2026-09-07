# frozen_string_literal: true

FactoryBot.define do
  factory :oc_replicated_work_item, class: 'OC::WorkItems::ReplicatedWorkItem' do
    project
    source_instance_uuid { '11111111-2222-3333-4444-555555555555' }
    sequence(:source_iid)
    source_kind { :issue }
    state { :imported }
    source_path { "#{source_instance_uuid}/#{source_kind.to_s.pluralize}/#{source_iid}.yml" }
    # Stands in for the blob oid of the source file. Random rather than derived:
    # nothing here hashes real content, and a derived value would suggest the
    # two are kept in step.
    source_blob_oid { SecureRandom.hex(20) }
    source_web_url { "https://peer.example.com/group/project/-/issues/#{source_iid}" }

    trait :merge_request_kind do
      source_kind { :merge_request }
      source_web_url { "https://peer.example.com/group/project/-/merge_requests/#{source_iid}" }
    end

    # A row that has no local record yet -- the state a merge request sits in
    # while its diff commits are missing.
    trait :deferred do
      state { :deferred }
      reason { 'diff commits not present' }
    end

    trait :skipped do
      state { :skipped }
      reason { 'confidential' }
    end

    # Ours, frozen, on its way to the instance named by source_instance_uuid.
    # source_path is our own old path rather than a path in their directory,
    # which is the one place these columns do not mean what they usually do --
    # see OC::ReplicatedWorkItem.
    trait :surrendered do
      state { :surrendered }
      source_web_url { nil }
      # Read straight off the settings rather than through
      # OC::WorkItems.instance_directory, which raises when there is no uuid --
      # true of the test environment unless a spec pins one, and a factory
      # should not make that a prerequisite for using it.
      source_path do
        "#{::Gitlab::CurrentSettings.uuid.presence || 'own-instance'}/issues/#{source_iid}.yml"
      end
    end

    # Theirs, now ours. The old owner's uuid, path and oid are all kept.
    trait :adopted do
      state { :adopted }
    end

    # Their document describes an item that was already here.
    trait :matched do
      state { :matched }
    end
  end
end
