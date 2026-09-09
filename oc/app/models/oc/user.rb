# frozen_string_literal: true

module OC
  module User
    extend ActiveSupport::Concern

    # A tier between administrator and simple-UI user: everything the full
    # interface offers, on one's own projects.
    def advanced
      # rubocop: disable Cop/UserAdmin -- an account tier, not a permission check
      !admin? && !external?
      # rubocop: enable Cop/UserAdmin
    end

    def developer?
      !external?
    end

    def dashboards
      ::ProjectsFinder.new(
        current_user: self,
        params: { min_access_level: ::Gitlab::Access::MAINTAINER, unfurl_type: ::OC::UNFURL_DASHBOARD }
      ).execute
    end

    # The signup flow creates the user's own dashboard, so the oldest one they
    # own is it.
    # rubocop: disable CodeReuse/ActiveRecord -- reordering the finder's own relation
    def own_dashboard
      @own_dashboard ||= dashboards.reorder(:created_at).find { |project| project.owner == self }
    end
    # rubocop: enable CodeReuse/ActiveRecord

    def active_dashboard
      @active_dashboard ||= own_dashboard
    end

    # Deliberately not persisted: a selection lasts for this object only.
    # rubocop: disable Gitlab/ModuleWithInstanceVariables -- paired with the reader above
    def active_dashboard=(project)
      @active_dashboard = project
    end
    # rubocop: enable Gitlab/ModuleWithInstanceVariables
  end
end
