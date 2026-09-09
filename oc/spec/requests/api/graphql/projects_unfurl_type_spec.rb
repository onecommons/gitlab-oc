# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Filtering projects by Unfurl type', feature_category: :source_code_management do
  include GraphqlHelpers

  let_it_be(:blueprint) { create(:project, :public) }
  let_it_be(:regular) { create(:project, :public) }

  let(:query) do
    graphql_query_for('projects', { unfurlType: :BLUEPRINT }, 'nodes { fullPath }')
  end

  before do
    blueprint.custom_attributes.create!(key: 'unfurl_type', value: OC::UNFURL_BLUEPRINT)
    regular.custom_attributes.create!(key: 'unfurl_type', value: OC::REGULAR_PROJECT)
  end

  it 'maps the enum value onto the stored classification' do
    post_graphql(query)

    expect(graphql_errors).to be_nil
    expect(graphql_data_at(:projects, :nodes).pluck('fullPath')).to contain_exactly(blueprint.full_path)
  end
end
