# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ApplicationHelper, feature_category: :navigation do
  describe '#support_url' do
    it 'points at the fork support project, not GitLab support' do
      expect(helper.support_url).to eq("#{Gitlab.config.gitlab.url}/onecommons/support")
    end

    context 'when the instance names its own' do
      before do
        stub_application_setting(help_page_support_url: 'https://example.com/help')
      end

      it 'leaves it alone' do
        expect(helper.support_url).to eq('https://example.com/help')
      end
    end
  end
end
