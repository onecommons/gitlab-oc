# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProjectCacheWorker, feature_category: :source_code_management do
  let(:project) { create(:project, :repository) }

  it 'classifies the project by its Unfurl files' do
    expect { described_class.new.perform(project.id) }
      .to change { project.custom_attributes.find_by(key: 'unfurl_type')&.value }
      .from(nil).to(OC::REGULAR_PROJECT)
  end

  it 'leaves a project without a repository alone' do
    empty = create(:project)

    described_class.new.perform(empty.id)

    expect(empty.custom_attributes.find_by(key: 'unfurl_type')).to be_nil
  end
end
