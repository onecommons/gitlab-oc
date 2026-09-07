# frozen_string_literal: true

require 'spec_helper'

# What the replica banner on the work item page asks for.
RSpec.describe 'Query.work_item(id).ocReplica', feature_category: :source_code_management do
  include GraphqlHelpers

  let_it_be(:user) { create(:user) }
  let_it_be(:project) { create(:project, :public, developers: user) }
  let_it_be_with_reload(:work_item) { create(:work_item, project: project) }

  let(:query) do
    graphql_query_for('workItem', { id: work_item.to_gid.to_s }, <<~FIELDS)
      id
      ocReplica {
        surrendered
        sourceWebUrl
      }
    FIELDS
  end

  let(:replica_data) { graphql_data.dig('workItem', 'ocReplica') }

  it 'is null for an ordinary work item' do
    post_graphql(query, current_user: user)

    expect(response).to have_gitlab_http_status(:ok)
    expect(graphql_data['workItem']).to include('id' => work_item.to_gid.to_s, 'ocReplica' => nil)
  end

  it 'says where the original lives for an imported copy' do
    create(:oc_replicated_work_item, project: project, issue: work_item,
      source_web_url: 'https://peer.example.com/group/project/-/issues/42')

    post_graphql(query, current_user: user)

    expect(replica_data).to eq(
      'surrendered' => false, 'sourceWebUrl' => 'https://peer.example.com/group/project/-/issues/42')
  end

  it 'says so for an item being transferred away, which has no original yet' do
    create(:oc_replicated_work_item, :surrendered, project: project, issue: work_item)

    post_graphql(query, current_user: user)

    expect(replica_data).to eq('surrendered' => true, 'sourceWebUrl' => nil)
  end

  # The row also records items this instance owns; those are not read-only and
  # get no banner.
  it 'is null for an item the row says is ours' do
    create(:oc_replicated_work_item, :adopted, project: project, issue: work_item)

    post_graphql(query, current_user: user)

    expect(replica_data).to be_nil
  end
end
