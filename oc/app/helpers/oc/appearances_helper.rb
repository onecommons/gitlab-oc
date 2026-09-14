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
      return super if current_appearance&.description?

      tag.div(class: 'oc-brand-holder') do
        safe_join([
          tag.p(_('Welcome to'), class: 'oc-sign-in-welcome'),
          tag.h2(_('The maker space for a better Internet.'), class: 'oc-sign-in-tagline')
        ])
      end
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
