# frozen_string_literal: true

module OC
  module ApplicationHelper
    extend ::Gitlab::Utils::Override

    # Upstream falls back to GitLab's own support desk. The fork's is a project
    # on the instance, and an admin that sets help_page_support_url still wins.
    override :support_url
    def support_url
      ::Gitlab::CurrentSettings.current_application_settings.help_page_support_url.presence ||
        ::Gitlab::Utils.append_path(::Gitlab.config.gitlab.url, 'onecommons/support')
    end

    # Sprockets appends its source map to the compiled stylesheet as a single
    # ~5 KB base64 comment, and the mailer layout inlines the whole string. One
    # line over RFC 5322's 998 characters makes Mail encode the entire HTML
    # part quoted-printable, which rewrites every `=`: `href="..."` is
    # assembled as `href=3D"..."`, so nothing reading the built message finds a
    # link. Mail clients decode it, but the map is 5 KB of nothing in every
    # message either way.
    override :asset_to_string
    def asset_to_string(name)
      super.sub(%r{\n?/\*# sourceMappingURL=data:.*?\*/}m, '')
    end
  end
end
