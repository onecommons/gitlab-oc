# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ImportWorker, feature_category: :source_code_management do
  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:developer) { create(:user) }
  let_it_be_with_reload(:project) { create(:project, namespace: owner.namespace) }

  let(:worker) { described_class.new }
  let(:run) { instance_double(OC::WorkItems::ImportRunService, execute: nil) }

  before_all do
    project.add_developer(developer)
  end

  before do
    allow(OC::WorkItems::ImportRunService).to receive(:new).and_return(run)
  end

  describe '#perform' do
    it 'does nothing for an unknown project' do
      expect(OC::WorkItems::ImportRunService).not_to receive(:new)

      worker.perform(non_existing_record_id, owner.id)
    end

    # A project that turned sync off is not opted back into it by someone
    # pushing a branch at it.
    it 'does nothing for a project that turned sync off' do
      project.enable_work_items_sync!(false)

      expect(OC::WorkItems::ImportRunService).not_to receive(:new)

      worker.perform(project.id, owner.id)
    end

    # destroy_issue is where GitLab draws this line: an import destroys and
    # rebuilds issues, so only a role that may delete one may start it.
    # And it is the only entry point that may start a transfer, for the same
    # reason: there is somebody who authorized it.
    it 'imports every peer directory when an owner pushed' do
      expect(run).to receive(:execute).with(directories: nil, initiate_transfers: true)

      worker.perform(project.id, owner.id)
    end

    # Skipped, not rejected: the push has already succeeded, and failing here
    # would surface as a git error the pusher cannot act on.
    it 'imports nothing when the pusher is not an owner' do
      expect(run).not_to receive(:execute)

      worker.perform(project.id, developer.id)
    end

    it 'says why it skipped, since nothing else will' do
      expect(::Gitlab::AppLogger).to receive(:info).with(
        hash_including(message: a_string_including('not authorized by an owner'), project_id: project.id))

      worker.perform(project.id, developer.id)
    end

    it 'imports nothing when the pushing user has since been deleted' do
      expect(run).not_to receive(:execute)

      worker.perform(project.id, non_existing_record_id)
    end

    # The one that matters most, because the caller can reach it by accident:
    # BranchHooksService passes `current_user&.id`, so a push nobody was
    # identified for arrives here as nil.
    #
    # Nil once selected the nightly's unauthenticated path, which imports every
    # peer directory on the branch -- so the way to import as nobody was to
    # push as nobody. There is no such path now: no user is no authorization,
    # and this is the only worker that can import an unbounded set.
    describe 'a push with no identified pusher' do
      it 'imports nothing at all' do
        expect(OC::WorkItems::ImportRunService).not_to receive(:new)
        expect(run).not_to receive(:execute)

        worker.perform(project.id, nil)
      end

      it 'imports nothing when the argument is left off entirely' do
        expect(run).not_to receive(:execute)

        worker.perform(project.id)
      end

      it 'logs the skip with no user to blame' do
        expect(::Gitlab::AppLogger).to receive(:info).with(
          hash_including(project_id: project.id, ::Labkit::Fields::GL_USER_ID => nil))

        worker.perform(project.id, nil)
      end
    end
  end
end
