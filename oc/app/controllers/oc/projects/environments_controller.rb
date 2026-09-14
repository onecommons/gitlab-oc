# frozen_string_literal: true

module OC
  module Projects
    module EnvironmentsController
      extend ActiveSupport::Concern
      extend ::Gitlab::Utils::Override

      prepended do
        include ::OC::RendersUnfurlDashboard
      end

      override :index
      def index
        return super unless unfurl_dashboard_project?

        render_unfurl_dashboard
      end

      override :show
      def show
        return super unless unfurl_dashboard_project?

        render_unfurl_dashboard
      end

      private

      # The dashboard links environments by name; everything else, and any
      # numeric id, goes to the stock lookup.
      #
      # A dashboard's environments come from its Unfurl files, and one can be
      # declared there without ever having been created through GitLab -- a
      # pushed or seeded dashboard has no rows at all. The app routes by name
      # and reads its own data, so a missing row is not a missing page: raising
      # here made the environments list link to its own 404.
      override :environment
      def environment
        id = params.permit(:id)[:id]
        return super if id.blank? || id.match?(/\A\d+\z/) || !unfurl_dashboard_project?

        # Only `show` renders the app and can do without the record. The other
        # actions on this lookup (edit, terminal, k8s) need one, and handing
        # them nil would turn a 404 into a 500.
        # rubocop: disable CodeReuse/ActiveRecord -- a name lookup the stock finder does not offer
        scope = project.environments
        @environment ||= action_name == 'show' ? scope.find_by(name: id) : scope.find_by!(name: id)
        # rubocop: enable CodeReuse/ActiveRecord
      end
    end
  end
end
