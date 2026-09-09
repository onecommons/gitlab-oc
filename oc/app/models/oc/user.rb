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

    # /home, the Dashboard sidebar entry and the deployment pages all resolve
    # through this project. The signup paths call it rather than a User
    # callback: a callback would also give one to every user an admin, the API,
    # a seed or a spec creates.
    def create_dashboard_project!
      return unless human?

      as_internal_user do
        project = ::Projects::CreateService.new(self, ::OC::DASHBOARD_PROJECT_ON_SIGNUP.dup).execute
        next unless project&.persisted?

        # The import runs in a worker, so nothing can classify this from its
        # files yet, and discovery reads what was recorded.
        project.record_unfurl_type!(::OC::UNFURL_DASHBOARD)
      end
    end

    private

    # An external user's projects_limit is zero, so they cannot create the
    # dashboard that is made for them. ensure_user_rights_and_limits sets the
    # limit from the flag, so flipping it back restores the zero.
    def as_internal_user
      was_external = external?

      if was_external
        self.external = false
        save(validate: false)
      end

      yield
    ensure
      if was_external
        self.external = true
        save(validate: false)
      end
    end
  end
end
