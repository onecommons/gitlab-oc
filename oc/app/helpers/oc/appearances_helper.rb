# frozen_string_literal: true

module OC
  module AppearancesHelper
    def default_brand_title
      'Unfurl'
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
