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

    # safe_format passes an already-safe link through and escapes everything
    # else, so a name carrying markup cannot reach the message raw.
    def admin_changed_password_text(format: nil)
      url = ::Gitlab.config.gitlab.url
      message = _('An administrator changed the password for your %{brand} account on %{link_to}.')

      return Kernel.format(message, brand: brand_title, link_to: url) unless format == :html

      safe_format(message, brand: brand_title, link_to: generate_link(url, url))
    end

    def instance_access_request_text(user, format: nil)
      safe_format(
        _('%{username} has asked for a %{brand} account on your instance %{host}:'),
        username: sanitize_name(user.name),
        brand: brand_title,
        host: gitlab_host_link(format)
      )
    end
  end
end
