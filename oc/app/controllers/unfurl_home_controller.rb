# frozen_string_literal: true

# OC Change #713 -- /home and /home/:username resolve to a dashboard project.
class UnfurlHomeController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index]

  feature_category :groups_and_projects

  def index
    return redirect_to new_user_session_path unless current_user

    redirect_to_dashboard(current_user)
  end

  def show
    redirect_to_dashboard(User.find_by_username(params.permit(:username)[:username]) || current_user)
  end

  private

  def redirect_to_dashboard(user)
    dashboard = user&.own_dashboard

    return redirect_to project_path(dashboard) if dashboard

    redirect_to new_project_path,
      alert: _('You do not have a dashboard project. Create one from the Unfurl project templates.')
  end
end
