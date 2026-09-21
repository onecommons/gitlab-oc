# frozen_string_literal: true

module OC
  module ApplicationHelper
    extend ::Gitlab::Utils::Override

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
