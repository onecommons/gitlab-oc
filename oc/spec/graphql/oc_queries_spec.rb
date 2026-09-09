# frozen_string_literal: true

require 'spec_helper'

# Gitlab::Graphql::Queries.all only walks app/assets/javascripts, so fork
# documents are never checked against the schema without this.
RSpec.describe 'oc graphql queries', feature_category: :api do
  Gitlab::Graphql::Queries.find(Rails.root.join('oc/app/assets/javascripts')).each do |definition|
    name = Pathname(definition.file).relative_path_from(Rails.root)

    it "#{name} is valid" do
      _, errors = definition.validate(GitlabSchema)

      expect(errors.map(&:message)).to be_empty
    end
  end
end
