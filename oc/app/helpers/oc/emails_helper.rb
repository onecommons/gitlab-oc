# frozen_string_literal: true

module OC
  # Mail is the fork's most-seen surface after the app itself, and upstream
  # names GitLab in the header logo and in a handful of account notices. Each
  # of these is a whole method, so the fork can take them here rather than
  # editing the templates that call them.
  module EmailsHelper
    def header_logo
      return super if current_appearance&.header_logo? && !current_appearance.header_logo.filename.ends_with?('.svg')

      image_tag(image_url('illustrations/unfurl_logo.png'), size: '164x33', alt: brand_title)
    end

    def two_factor_authentication_disabled_text
      format(_('Two-factor authentication has been disabled for your %{brand} account.'), brand: brand_title)
    end

    def new_email_address_added_text(email)
      format(
        _('A new email address has been added to your %{brand} account: %{email}'),
        brand: brand_title, email: email
      )
    end
  end
end
