# frozen_string_literal: true

module OC
  module SidebarsHelper
    # The fork ships neither GitLab's version nor its release announcements, so
    # the help centre's version badge and What's new item have nothing to say.
    def super_sidebar_shared_context(panel:, panel_type:)
      super.merge(display_whats_new: false, show_version_check: false)
    end
  end
end
