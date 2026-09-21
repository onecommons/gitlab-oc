# frozen_string_literal: true

module OC
  module EmailsHelperTestHelper
    extend ::Gitlab::Utils::Override

    # OC::EmailsHelper#header_logo serves the fork's wordmark, so the alt text
    # is whatever brand_title resolves to -- the appearance title in the
    # examples that create one, the fork's default otherwise.
    override :default_header_logo
    def default_header_logo
      %r{<img alt="[^"]*" src="http://test\.host/images/illustrations/unfurl_logo\.png" width="\d+" height="\d+" />}
    end
  end
end
