# frozen_string_literal: true

module OC
  module AppearancesHelper
    def default_brand_title
      'Unfurl'
    end

    # The sign-in page's left column. 19.3 renders one only when the instance
    # has an appearance description, and drops to a single centred column
    # otherwise, which is what left the fork's sign-in page unbranded beside
    # the form. An instance that sets its own description still wins.
    def custom_sign_in_description
      return super unless oc_brand_column?

      tag.div(class: 'oc-brand-holder') do
        safe_join([
          tag.p(_('Welcome to'), class: 'oc-sign-in-welcome'),
          oc_wordmark('oc-sign-in-logo'),
          tag.h2(_('The maker space for a better Internet.'), class: 'oc-sign-in-tagline')
        ])
      end
    end

    # Both variants ship and CSS picks one. A server-side choice cannot work
    # here: signed-out visitors get the instance default, which is usually the
    # Auto mode (`gl-system`), where the page follows prefers-color-scheme and
    # `user_application_dark_mode?` is false however the page actually renders.
    def oc_wordmark(css_class)
      tag.div(class: css_class) do
        safe_join([
          image_tag(brand_image_path, alt: brand_title, lazy: false, class: 'oc-logo-light'),
          image_tag('illustrations/uf-logo-white.svg', alt: '', lazy: false,
            aria: { hidden: true }, class: 'oc-logo-dark')
        ])
      end
    end

    def oc_brand_column?
      !current_appearance&.description?
    end

    # Upstream's is GitLab's own mark. Used by the sign-in header bar, the help
    # footer, the terms page and the IDE -- not by the super topbar, which the
    # fork brands separately.
    def brand_header_logo(options = {})
      return super if current_appearance&.header_logo?

      oc_wordmark('oc-header-logo')
    end

    # 15.11 put a brand bar above the sign-in and sign-up pages; 19.3's devise
    # layout dropped it. This is the only hook it still renders at the top of
    # the body, and the bar belongs on devise pages alone -- everywhere else
    # the topbar already carries the mark.
    def header_message
      return super if current_appearance&.show_header?
      return super unless respond_to?(:devise_controller?) && devise_controller?

      render 'layouts/header/empty'
    end

    # Upstream ships this hidden (`gl-invisible`) and lazy, and un-hides it in
    # the image's load handler. Both halves fail for the fork's mark. A browser
    # will not load a lazy image that is not visible, so the class and the load
    # event wait on each other; and once it is eager it finishes loading before
    # the handler is attached, so the one-shot listener never fires either.
    #
    # The class exists so a portrait logo does not flash at the wrong size. The
    # fork's is landscape, so there is nothing to detect and nothing to hide.
    # An instance that uploads its own logo keeps upstream's behaviour.
    def brand_image
      return super if current_appearance&.logo?
      # The fork's own column carries the wordmark inside the sentence it
      # completes, so the layout's copy above the form would be a second one.
      return safe_join([]) if oc_brand_column?

      image_tag(brand_image_path, alt: brand_title, lazy: false, class: 'gl-h-10')
    end

    # The sign-in page's logo is an <img>, so the topbar's inline wordmark
    # cannot serve here: external CSS never reaches an image's own document,
    # and logo.js waits on a load event to un-hide it.
    def brand_image_path
      return super if current_appearance&.logo?

      image_path('illustrations/uf-logo.svg')
    end
  end
end
