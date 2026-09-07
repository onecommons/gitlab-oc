# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Repository, feature_category: :source_code_management do
  let(:repository) { create(:project, :repository).repository }

  describe '#refresh_method_caches' do
    it 'expires and reloads the Unfurl dashboard-file cache' do
      expect(repository).to receive(:expire_method_caches).with([:unfurl_yaml])
      expect(repository).to receive(:unfurl_yaml)

      repository.refresh_method_caches([:unfurl_yaml])
    end

    it 'expires and reloads the Unfurl ensemble-template cache' do
      expect(repository).to receive(:expire_method_caches).with([:ensemble_template_yaml])
      expect(repository).to receive(:ensemble_template_yaml)

      repository.refresh_method_caches([:ensemble_template_yaml])
    end
  end

  describe '#expire_unfurl_caches' do
    it 'expires both Unfurl repository-file caches together' do
      expect(repository).to receive(:expire_method_caches).with(%i[unfurl_yaml ensemble_template_yaml])

      repository.expire_unfurl_caches
    end
  end
end
