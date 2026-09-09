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
      override :environment
      def environment
        id = params.permit(:id)[:id]
        return super if id.blank? || id.match?(/\A\d+\z/) || !unfurl_dashboard_project?

        # rubocop: disable CodeReuse/ActiveRecord -- a name lookup the stock finder does not offer
        @environment ||= project.environments.find_by!(name: id)
        # rubocop: enable CodeReuse/ActiveRecord
      end
    end
  end
end
