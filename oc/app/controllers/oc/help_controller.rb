# frozen_string_literal: true

module OC
  # Serves the fork's own pages from oc/doc, beside upstream's doc/.
  module HelpController
    extend ::Gitlab::Utils::Override

    # The fork's help landing page shows two more documents beside the index.
    override :index
    def index
      super

      @help_index_faqs = oc_markdown('index_faqs.md')
      @developer_guide = oc_markdown('developer_guide.md')
    end

    # With no docs site configured, upstream's index rather than docs.gitlab.com.
    # Read from doc/ directly: path_to_doc would pick the fork's index.
    override :redirect_to_docs
    def redirect_to_docs
      return super if documentation_base_url

      @path = 'docs'
      @markdown = markdown_for(File.join(Rails.root, 'doc', '_index.md'))
      render :show, formats: :html
    end

    override :show
    def show
      # From .../page/ a browser resolves the page's relative links one folder too deep.
      requested = request.original_fullpath.split('?').first
      return redirect_to(requested.chomp('/'), status: :moved_permanently) if requested.end_with?('/')

      # Upstream serves doc/ images except SVG, which the docs use for diagrams.
      # An SVG opened on its own can run script, so this one runs none.
      svg = params.permit(:path, :format)
      return super unless svg[:format] == 'svg'

      path = path_to_doc("#{Rack::Utils.clean_path_info(svg[:path])}.svg")
      return head :not_found unless File.exist?(path)

      response.headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
      send_file(path, type: 'image/svg+xml', disposition: 'inline')
    end

    private

    # Upstream's own reader, so frontmatter is stripped the same way. Neither
    # file has a doc/ counterpart, so path_to_doc's fallback cannot fire.
    def oc_markdown(file_name)
      path = File.join(Rails.root, 'oc', 'doc', file_name)
      return unless File.exist?(path)

      markdown_for(path)
    end

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
