# frozen_string_literal: true

module OC
  module PageLayoutHelper
    extend ::Gitlab::Utils::Override

    # Upstream swaps in a blue mark in development so a GitLab engineer can tell
    # a local tab from gitlab.com. The fork ships its own as favicon.png, which
    # already wins on the asset path, and seeing it is the point of shipping it.
    override :favicon
    def favicon
      return super unless Rails.env.development?
      return super if ::Appearance.current&.favicon&.exists?

      image_path('favicon.png')
    end

    # The card an external site shows for a link here. Upstream's default is
    # GitLab's own; there is no seam for it, so the method comes across whole.
    override :page_image
    def page_image
      subject = @project || @user || @group
      image = subject.avatar_url(only_path: false) if subject.present?

      image || image_url('uf-logo.png')
    end
  end
end
