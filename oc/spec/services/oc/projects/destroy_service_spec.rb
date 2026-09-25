# frozen_string_literal: true

require 'spec_helper'

# The override lives on OC::Projects::DestroyService and is only reachable
# through the upstream class it is prepended onto.
RSpec.describe OC::Projects::DestroyService, feature_category: :source_code_management do
  let_it_be(:owner) { create(:user, :with_namespace) }
  let!(:project) { create(:project, :repository, namespace: owner.namespace) }

  subject(:destroy_project) { ::Projects::DestroyService.new(project, owner).execute }

  it 'leaves a tombstone carrying the path the project had' do
    full_path = project.full_path

    expect { destroy_project }.to change { OC::Projects::CloudmapEvent.count }.by(1)

    event = OC::Projects::CloudmapEvent.last
    expect(event).to be_project_deleted
    expect(event.project_path).to eq(full_path)
    # The foreign key nullifies during the destroy; the path is all that is
    # left naming the project, which is why it is a column.
    expect(event.project_id).to be_nil
    expect(event.organization_id).to eq(owner.namespace.organization_id)
  end

  it 'records nothing when the user may not remove the project' do
    outsider = create(:user)

    expect { ::Projects::DestroyService.new(project, outsider).execute }
      .not_to change { OC::Projects::CloudmapEvent.count }
  end

  # A failure to record must not turn a completed deletion into a failed one.
  it 'still reports success when recording raises' do
    allow(OC::Projects::CloudmapEvent).to receive(:record_deletion).and_raise(ActiveRecord::StatementInvalid)

    expect(destroy_project).to be(true)
  end
end
