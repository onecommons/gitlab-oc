# frozen_string_literal: true

module OC
  # OC Change -- a group marked with CLOUDMAP_INCLUDE_ALL_PUBLIC puts every
  # public project beneath it, at any depth, in the cloudmap, whatever its
  # unfurl type. Set through the admin custom attributes API.
  module GroupCustomAttribute
    extend ActiveSupport::Concern

    CLOUDMAP_INCLUDE_ALL_PUBLIC = 'cloudmap_include_all_public'

    prepended do
      scope :including_all_public_in_cloudmap, -> { where(key: CLOUDMAP_INCLUDE_ALL_PUBLIC, value: 'true') }

      # Only turning the mark on is recorded. Turning it off leaves what the
      # cloudmap already has alone.
      after_commit :record_cloudmap_inclusion, on: %i[create update], if: :cloudmap_inclusion_turned_on?
    end

    class_methods do
      def cloudmap_including_group_ids
        including_all_public_in_cloudmap.pluck(:group_id)
      end
    end

    private

    def cloudmap_inclusion_turned_on?
      key == CLOUDMAP_INCLUDE_ALL_PUBLIC && value == 'true' && saved_change_to_value?
    end

    # The hierarchy's projects, so the worker sends those already public.
    def record_cloudmap_inclusion
      ::OC::Projects::CloudmapEvent.record_for_namespace_quietly(
        ::OC::Projects::CloudmapEvent.namespace_snapshot(group), kind: :group_included)
    end
  end
end
