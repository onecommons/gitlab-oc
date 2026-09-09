# frozen_string_literal: true

namespace :explore do
  # OC Change #1082 -- the tabs are client-side routes under this path
  resources :blueprints, only: [:index] do
    collection do
      get :verified, to: 'blueprints#index'
      get :starred, to: 'blueprints#index'
      get :all, to: 'blueprints#index'
    end
  end
end

# Upstream's /explore lists projects; the fork leads with blueprints.
get '/explore', to: redirect('explore/blueprints', status: 302), as: :oc_explore_blueprints_redirect
