# frozen_string_literal: true

module OC
  # Serves the fork's own pages from oc/doc, beside upstream's doc/.
  module HelpController
    extend ::Gitlab::Utils::Override

    private

    override :path_to_doc
    def path_to_doc(file_name)
      oc_path = File.join(Rails.root, 'oc', 'doc', file_name)

      File.exist?(oc_path) ? oc_path : super
    end

    # An instance that points /help at docs.gitlab.com would send readers of a
    # fork page to a URL that does not exist there.
    override :redirect_to_documentation_website?
    def redirect_to_documentation_website?
      return false if File.exist?(File.join(Rails.root, 'oc', 'doc', "#{@path}.md"))

      super
    end
  end
end
