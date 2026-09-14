# frozen_string_literal: true

module OC
  module UsersHelper
    # OC Change #1000 -- which interface the profile's owner is using.
    #
    # 15.11 called these levels and read admin/developer/external directly. The
    # fork now stores the choice as the interface a signup picked, so this says
    # the same thing in the words the settings page uses.
    def oc_interface_text(user)
      # rubocop: disable Cop/UserAdmin -- an account tier, not a permission check
      return _('Admin') if user.admin?

      # rubocop: enable Cop/UserAdmin
      user.external? ? _('Deploy applications') : _('Develop applications')
    end
  end
end
