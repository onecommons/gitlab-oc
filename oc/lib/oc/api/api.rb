# frozen_string_literal: true

module OC
  module API
    module API
      extend ActiveSupport::Concern

      prepended do
        mount ::API::UnfurlAccessToken
        mount OC::API::ProjectMirror
      end
    end
  end
end
