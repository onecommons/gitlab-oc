# frozen_string_literal: true

module OC
  module Gitlab
    module GonHelper
      extend ::Gitlab::Utils::Override

      override :add_gon_variables
      def add_gon_variables
        super

        # oc-pages talks to the same-origin /services/unfurl-server path unless told otherwise.
        unfurl_server_url = ::OC::Repositories::UnfurlServer.browser_url
        gon.unfurl_server_url = unfurl_server_url if unfurl_server_url.present?
      end
    end
  end
end
