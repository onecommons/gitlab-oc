# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::ImportReconciler, feature_category: :source_code_management do
  include WorkItemSyncPaths

  # let, not let_it_be: the repository is Gitaly state and does not roll back
  # with the database, so a shared project would carry every example's seeded
  # files into the next one.
  let(:project) { create(:project, :repository) }

  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:reconciler) { described_class.new(project) }

  # Files are put on the branch directly rather than by running a sync: the
  # reconciler's whole job is to read someone else's directory, and nothing
  # local produces one.
  def seed(path, content = "_schema: issues@1\n")
    project.repository.create_file(
      project.first_owner, path, content, message: 'seed', branch_name: branch)
  end

  def oid_of(path)
    project.repository.blob_at(project.repository.commit(branch).sha, path).id
  end

  def plan
    reconciler.plan(peer)
  end

  # The question deferred when the layout moved under <uuid>/: scoping a tree
  # read to a directory must not change what the entry paths mean. If Gitaly
  # returned them relative to the requested directory, every lookup against a
  # stored path would miss -- the writer would recreate files that already
  # exist, and the importer would import every file twice.
  describe 'the path form Gitaly returns' do
    it 'roots entry paths at the repository even for a scoped read' do
      seed("#{peer}/issues/1.yml")

      tree = project.repository.tree(project.repository.commit(branch).sha, peer, recursive: true)
      blobs = tree.entries.select { |entry| entry.type == :blob }

      # Full paths, not "issues/1.yml" relative to the directory asked for.
      expect(blobs.map(&:path)).to contain_exactly("#{peer}/issues/1.yml")

      # A recursive read also lists the directories it descended through, which
      # is why every caller filters on type rather than trusting the listing.
      expect(tree.entries.map(&:path)).to include("#{peer}/issues")
    end
  end

  describe '#peer_directories' do
    it 'is empty when the branch does not exist' do
      expect(reconciler.peer_directories).to be_empty
    end

    it 'lists other instances and never our own' do
      seed("#{peer}/issues/1.yml")
      seed(sync_path('issues/9.yml'))
      seed("#{OC::WorkItems.instance_directory}/labels.yml", "_schema: labels@1\n")

      expect(reconciler.peer_directories).to contain_exactly(peer)
    end
  end

  describe '#plan' do
    it 'is empty when the branch does not exist' do
      expect(plan).to be_empty
    end

    it 'imports a path it has no row for' do
      seed("#{peer}/issues/7.yml")

      expect(plan).to contain_exactly(
        have_attributes(kind: :import, path: "#{peer}/issues/7.yml",
          source_kind: :issue, source_iid: 7, replica: nil))
    end

    it 'reads the kind and iid out of a merge request path' do
      seed("#{peer}/merge_requests/12.yml", "_schema: merge_requests@1\n")

      expect(plan).to contain_exactly(
        have_attributes(kind: :import, source_kind: :merge_request, source_iid: 12))
    end

    it 'does nothing for a file whose oid still matches its row' do
      seed("#{peer}/issues/7.yml")
      create(:oc_replicated_work_item, project: project, source_instance_uuid: peer,
        source_path: "#{peer}/issues/7.yml", source_blob_oid: oid_of("#{peer}/issues/7.yml"))

      expect(plan).to be_empty
    end

    it 'rebuilds when the source file changed under an existing row' do
      seed("#{peer}/issues/7.yml")
      replica = create(:oc_replicated_work_item, project: project, source_instance_uuid: peer,
        source_path: "#{peer}/issues/7.yml", source_blob_oid: 'a' * 40)

      expect(plan).to contain_exactly(
        have_attributes(kind: :rebuild, replica: replica, oid: oid_of("#{peer}/issues/7.yml")))
    end

    # The one case where an unchanged file still means work: what blocked a
    # deferred row may have arrived since, and the file will never change again
    # to tell us so.
    it 'rechecks a deferred row even though nothing changed' do
      seed("#{peer}/merge_requests/3.yml", "_schema: merge_requests@1\n")
      path = "#{peer}/merge_requests/3.yml"
      replica = create(:oc_replicated_work_item, :deferred, :merge_request_kind,
        project: project, source_instance_uuid: peer,
        source_path: path, source_blob_oid: oid_of(path))

      expect(plan).to contain_exactly(have_attributes(kind: :recheck, replica: replica))
    end

    it 'leaves a skipped row alone while its file is unchanged' do
      seed("#{peer}/issues/7.yml")
      create(:oc_replicated_work_item, :skipped, project: project, source_instance_uuid: peer,
        source_path: "#{peer}/issues/7.yml", source_blob_oid: oid_of("#{peer}/issues/7.yml"))

      expect(plan).to be_empty
    end

    it 'deletes a replica whose source file is gone' do
      seed("#{peer}/issues/7.yml")
      replica = create(:oc_replicated_work_item, project: project, source_instance_uuid: peer,
        source_path: "#{peer}/issues/999.yml", source_blob_oid: 'b' * 40)

      expect(plan).to include(have_attributes(kind: :delete, replica: replica))
    end

    it 'ignores catalogs, ids.yml and commit notes' do
      seed("#{peer}/labels.yml", "_schema: labels@1\n")
      seed("#{peer}/milestones.yml", "_schema: milestones@1\n")
      seed("#{peer}/ids.yml", "_schema: ids@1\n")
      seed("#{peer}/commit_notes/f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42.yml",
        "_schema: commit_notes@1\n")

      expect(plan).to be_empty
    end

    it 'never looks at another instance directory, including our own' do
      seed(sync_path('issues/4.yml'))
      seed("#{peer}/issues/7.yml")

      expect(plan.map(&:path)).to contain_exactly("#{peer}/issues/7.yml")
    end

    # Rows belonging to a different peer must not be read as deletions just
    # because their paths are absent from this directory.
    it 'ignores rows recorded against another instance' do
      seed("#{peer}/issues/7.yml")
      create(:oc_replicated_work_item, project: project,
        source_instance_uuid: '99999999-8888-7777-6666-555555555555',
        source_path: '99999999-8888-7777-6666-555555555555/issues/1.yml')

      expect(plan.map(&:kind)).to contain_exactly(:import)
    end

    it 'ignores rows belonging to another project' do
      seed("#{peer}/issues/7.yml")
      create(:oc_replicated_work_item, source_instance_uuid: peer,
        source_path: "#{peer}/issues/7.yml")

      expect(plan.map(&:kind)).to contain_exactly(:import)
    end

    # A transfer ends with a row whose local record is ours, not a copy. Both
    # of the shapes below look exactly like drift to a reconcile that goes by
    # oids alone, and in both the action it would produce destroys a record
    # this instance owns.
    describe 'rows a transfer has finished with' do
      it 'says nothing about an adopted row whose file became a reference' do
        seed("#{peer}/issues/7.yml", "_schema: issue_reference@1\n")
        create(:oc_replicated_work_item, :adopted, project: project, source_instance_uuid: peer,
          source_path: "#{peer}/issues/7.yml", source_blob_oid: 'a' * 40)

        expect(plan).to be_empty
      end

      # Not just "no rebuild": the path must still be recognised. Leaving the
      # row out of the lookup would read the file as one nobody has imported,
      # and the run would import the new owner's own document back as a copy of
      # itself.
      it 'does not import an adopted row path as though it were new' do
        seed("#{peer}/issues/7.yml")
        create(:oc_replicated_work_item, :adopted, project: project, source_instance_uuid: peer,
          source_path: "#{peer}/issues/7.yml", source_blob_oid: 'a' * 40)

        expect(plan).to be_empty
      end

      it 'says nothing about an adopted row whose file is gone' do
        seed("#{peer}/issues/1.yml")
        create(:oc_replicated_work_item, :adopted, project: project, source_instance_uuid: peer,
          source_path: "#{peer}/issues/7.yml", source_blob_oid: 'a' * 40)

        expect(plan.map(&:kind)).to contain_exactly(:import)
      end

      # A surrendered row is filed under the *new owner's* uuid while its path
      # names our own directory, so it can never match anything in the
      # directory being scanned. Without the guard it would read as a file that
      # had vanished on every single run, and delete the frozen original.
      it 'never reads a surrendered row as a deletion' do
        seed("#{peer}/issues/1.yml")
        create(:oc_replicated_work_item, :surrendered, project: project,
          source_instance_uuid: peer, source_iid: 42)

        expect(plan.map(&:kind)).to contain_exactly(:import)
      end
    end
  end
end
