# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Auth, feature_category: :system_access do
  describe '.build_authentication_abilities' do
    subject(:abilities) { described_class.build_authentication_abilities }

    # A deployment runs as a CI job and commits its results back, so its job
    # token needs to push. Upstream grants build_push_code, which is not it.
    it 'lets a job token push' do
      expect(abilities).to include(:push_code)
    end

    it 'leaves the abilities upstream grants alone' do
      expect(abilities).to include(:read_project, :build_download_code, :build_push_code)
    end

    it 'does not reach the API' do
      expect(abilities).not_to include(:api)
    end
  end
end
