# frozen_string_literal: true

# Fork-owned top-level routes. These are drawn before upstream's, so nothing
# here may use a wildcard segment under a namespace upstream owns: it would
# swallow every route a later release adds there.

# OC Change #713 -- a user's dashboard project is reachable by name
resources(:home,
  as: :unfurl_home,
  controller: :unfurl_home,
  param: :username,
  only: [:index, :show])

# OC Change #172, #1064 -- the dashboard app lived under /dashboard until 2022,
# and these are bookmarks. Each names a second segment upstream does not use.
scope :dashboard do
  # Found, not moved permanently: a browser that cached a 301 here would keep
  # following it if upstream ever claims one of these paths.
  %w[applications deployments environments settings].each do |legacy|
    get legacy, to: redirect('home', status: 302), as: :"oc_legacy_dashboard_#{legacy}"
    get "#{legacy}/*rest", to: redirect('home', status: 302), as: :"oc_legacy_dashboard_#{legacy}_rest"
  end
end

# OC Change #1259 -- the marketing site owns these paths
%w[about blog developer-guide discord faq guide news privacypolicy terms].each do |page|
  name = page.tr('-', '_')

  get page, to: redirect("https://www.unfurl.cloud/#{page}"), as: :"static_#{name}"
  get "#{page}/*rest",
    to: redirect { |params, _request| "https://www.unfurl.cloud/#{page}/#{params[:rest]}" },
    as: :"static_#{name}_rest"
end
