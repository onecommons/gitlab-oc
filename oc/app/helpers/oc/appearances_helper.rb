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

    # The sign-in page's logo is an <img>, so the topbar's inline wordmark
    # cannot serve here: external CSS never reaches an image's own document,
    # and logo.js waits on a load event to un-hide it.
    def brand_image_path
      return super if current_appearance&.logo?

      image_path('illustrations/uf-logo.svg')
    end
  end
end
