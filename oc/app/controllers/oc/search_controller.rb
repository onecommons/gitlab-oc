# frozen_string_literal: true

module OC
  module SearchController
    extend ActiveSupport::Concern

    prepended do
      before_action :ensure_not_simple_interface
    end

    private

    # A simple-interface user gets their deployments, not the whole instance.
    def ensure_not_simple_interface
      render_404 if current_user&.external?
    end
  end
end
