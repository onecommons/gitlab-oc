# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Graphql::Limit::FieldCallCount, feature_category: :database do
  let(:extension) { described_class.allocate }

  def query_id_for(query)
    extension.send(:fetch_query_id, Struct.new(:query).new(query))
  end

  it 'uses the query fingerprint as the field-call accounting key' do
    query = instance_double(GraphQL::Query, fingerprint: 'batched-query-fingerprint')

    expect(query_id_for(query)).to eq('batched-query-fingerprint')
  end

  # Why the fork keys on fingerprint rather than operation_fingerprint: the
  # dashboard batches one query over several projects, and a shared key would
  # spend the whole `limit: 1` on the first entry.
  it 'tells apart two entries of a batch that differ only in their variables' do
    first = GraphQL::Query.new(GitlabSchema, '{ __typename }', variables: { 'fullPath' => 'a/one' })
    second = GraphQL::Query.new(GitlabSchema, '{ __typename }', variables: { 'fullPath' => 'a/two' })

    expect(first.operation_fingerprint).to eq(second.operation_fingerprint)
    expect(query_id_for(first)).not_to eq(query_id_for(second))
  end

  it 'is blank when the query cannot supply one' do
    query = instance_double(GraphQL::Query)
    allow(query).to receive(:fingerprint).and_raise(TypeError)

    expect(query_id_for(query)).to eq('')
  end
end
