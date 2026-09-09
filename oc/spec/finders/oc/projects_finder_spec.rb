# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProjectsFinder, feature_category: :groups_and_projects do
  let(:user) { create(:user) }
  let(:blueprint) { create(:project, :public) }
  let(:dashboard) { create(:project, :public) }
  let(:regular) { create(:project, :public) }
  let(:unclassified) { create(:project, :public) }

  before do
    { blueprint => OC::UNFURL_BLUEPRINT, dashboard => OC::UNFURL_DASHBOARD, regular => OC::REGULAR_PROJECT }
      .each { |project, type| project.custom_attributes.create!(key: 'unfurl_type', value: type) }
  end

  def find(params)
    described_class.new(current_user: user, params: params).execute
  end

  it 'filters by each Unfurl classification' do
    expect(find(unfurl_type: OC::UNFURL_BLUEPRINT)).to contain_exactly(blueprint)
    expect(find(unfurl_type: OC::UNFURL_DASHBOARD)).to contain_exactly(dashboard)
    expect(find(unfurl_type: OC::REGULAR_PROJECT)).to contain_exactly(regular)
  end

  it 'ignores a missing or unknown type' do
    all = [blueprint, dashboard, regular, unclassified]

    expect(find({})).to match_array(all)
    expect(find(unfurl_type: 'NotAType')).to match_array(all)
  end
end
