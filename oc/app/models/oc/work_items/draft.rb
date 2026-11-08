# frozen_string_literal: true

module OC
  module WorkItems
    # One row per draft file an installation has created an issue from, keyed
    # by the draft's file name. It makes a draft pushed twice a no-op, lets a
    # later draft say #draft:<key> for an earlier one, and names the issue's
    # file (`<iid>-<key>.yml`). A key stays spent after its issue is deleted.
    class Draft < ApplicationRecord
      self.table_name = 'oc_work_item_drafts'

      # Explicitly top-level: inside `module OC` a bare `Issue` resolves to the
      # prepended OC::Issue module. See ReplicatedWorkItem.
      belongs_to :project, class_name: '::Project'
      belongs_to :issue, class_name: '::Issue', optional: true

      validates :key, presence: true, length: { maximum: 64 }, format: { with: DraftFile::KEY_PATTERN },
        uniqueness: { scope: :project_id }
      validates :iid, presence: true

      scope :for_project, ->(project) { where(project: project) }
    end
  end
end
