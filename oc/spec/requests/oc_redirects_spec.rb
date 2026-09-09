# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Fork-owned redirects', feature_category: :groups_and_projects do
  describe 'the marketing site' do
    it 'redirects a page and everything below it' do
      get '/developer-guide'
      expect(response).to redirect_to('https://www.unfurl.cloud/developer-guide')

      get '/blog/some-post'
      expect(response).to redirect_to('https://www.unfurl.cloud/blog/some-post')
    end
  end

  describe 'the paths the dashboard app used before 2022' do
    it 'sends them to the dashboard project' do
      get '/dashboard/deployments'
      expect(response).to redirect_to('/home')

      get '/dashboard/environments/production'
      expect(response).to redirect_to('/home')
    end
  end
end
