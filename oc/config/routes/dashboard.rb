# frozen_string_literal: true

# OC Change -- the Your Work tabs the fork adds are client-side routes the
# server has to answer as well, so a reload keeps the tab.
resource :dashboard, controller: 'dashboard', only: [] do
  scope module: :dashboard do
    resources :projects, only: [] do
      collection do
        get :dashboards, to: 'projects#index'
        get :blueprints, to: 'projects#index'
      end
    end
  end
end
