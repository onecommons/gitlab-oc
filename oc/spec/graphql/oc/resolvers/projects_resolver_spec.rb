# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Resolvers::ProjectsResolver, feature_category: :source_code_management do
  include GraphqlHelpers

  let_it_be(:blueprints) { create(:group, path: 'blueprints') }
  let_it_be(:verified) { create(:project, :public, group: blueprints) }
  let_it_be(:community) { create(:project, :public) }
  let_it_be(:regular) { create(:project, :public) }

  let(:current_user) { nil }

  subject(:resolved) { resolve(described_class, obj: nil, args: args, ctx: { current_user: current_user }).items }

  before do
    [verified, community].each do |project|
      project.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_BLUEPRINT)
    end
    regular.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
  end

  context 'with unfurlType' do
    let(:args) { { unfurl_type: OC::UNFURL_BLUEPRINT } }

    it 'returns every blueprint an anonymous visitor can see' do
      expect(resolved).to contain_exactly(verified, community)
    end
  end

  context 'with unfurlType and namespacePath' do
    let(:args) { { unfurl_type: OC::UNFURL_BLUEPRINT, namespace_path: blueprints.full_path } }

    it 'returns only the blueprints in that namespace' do
      expect(resolved).to contain_exactly(verified)
    end
  end

  context 'without unfurlType' do
    let(:args) { {} }

    it 'is unfiltered' do
      expect(resolved).to contain_exactly(verified, community, regular)
    end
  end
end
