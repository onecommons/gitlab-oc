# frozen_string_literal: true

module OC
  module RootController
    extend ::Gitlab::Utils::Override

    private

    # The default landing page is the user's own dashboard project. Both keys
    # are handled because the personal_homepage rollout swaps them.
    override :dashboard_redirect_path
    def dashboard_redirect_path(dashboard_type)
      return super unless %w[projects homepage].include?(dashboard_type)

      dashboard = current_user.own_dashboard
      return project_path(dashboard) if dashboard

      flash[:alert] = _('You do not have a dashboard project. Create one from the Unfurl project templates.')
      new_project_path
    end
  end
end
