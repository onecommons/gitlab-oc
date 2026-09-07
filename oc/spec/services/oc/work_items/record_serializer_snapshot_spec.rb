# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_snapshots'

# Documents the exact on-disk format of the work items sync branch, and
# regenerates the committed snapshots on demand.
#
# By default these examples VERIFY oc/spec/fixtures/work_items/*.yml byte for
# byte. After a deliberate schema change -- a GitLab upgrade touching
# lib/gitlab/import_export/project/import_export.yml, or an intentional change
# to the serializer -- regenerate them:
#
#   REGENERATE_WORK_ITEM_SNAPSHOTS=1 \
#   PATH="$(asdf where golang 1.19.2)/bin:$PATH" \
#   ASDF_GOLANG_VERSION=1.19.2 \
#   DEVELOPER_DIR=/Applications/Xcode_16.2.app/Contents/Developer \
#   bundle exec rspec oc/spec/services/oc/work_items/record_serializer_snapshot_spec.rb
#
# then review the diff. A regeneration run also verifies what it wrote, so a
# green run means the new snapshots are correct, not merely written.
#
# An unexpected failure here means the serializer's output drifted
# unintentionally -- read the diff before reaching for the regenerate command.
#
# Snapshot testing in the sense used by spec/requests/api/markdown_snapshot_spec.rb,
# not the Jest sense. See doc/development/gitlab_flavored_markdown/
# specification_guide/index.md for GitLab's description of the approach.
RSpec.describe OC::WorkItems::RecordSerializer, 'Snapshot', feature_category: :source_code_management do
  include WorkItemSnapshots

  subject(:serializer) { described_class.new }

  let(:regenerate) { ENV['REGENERATE_WORK_ITEM_SNAPSHOTS'].present? }

  # Writes the snapshot when regenerating, then verifies either way, so both
  # modes end up asserting the same equality.
  def expect_snapshot_or_regenerate!(basename, actual, substitutions)
    path = snapshot_path(basename)

    if regenerate
      File.write(path, placeholderize(actual, substitutions))
      warn "regenerated #{path}"
    end

    raise "#{path} is missing. Regenerate it: see the comment at the top of #{__FILE__}" unless path.exist?

    expected = format(strip_example_comments(File.read(path)), **substitutions)

    expect(actual).to eq(expected)
  end

  it 'issues/<iid>.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      issue, substitutions = build_snapshot_issue

      expect_snapshot_or_regenerate!('issue.yml', serializer.to_yaml(issue), substitutions)
    end
  end

  it 'merge_requests/<iid>.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      merge_request, substitutions = build_snapshot_merge_request

      expect_snapshot_or_regenerate!('merge_request.yml', serializer.to_yaml(merge_request), substitutions)
    end
  end

  # An imported item occupies the same path a document would, and this is what
  # a reader finds there instead: where the real item is, and what this
  # instance decided the source's ids mean here.
  it 'issues/<iid>.yml matches the committed snapshot when the item is a replica' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      replica, substitutions = build_snapshot_reference

      expect_snapshot_or_regenerate!('issue_reference.yml', serializer.to_yaml(replica), substitutions)
    end
  end

  it 'commit_notes/<sha>.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      project, commit_id, notes, substitutions = build_snapshot_commit_notes

      expect_snapshot_or_regenerate!(
        'commit_notes.yml',
        serializer.to_yaml_commit_notes(project, commit_id, notes),
        substitutions)
    end
  end

  # ids.yml is not serialized from records of its own: the serializer builds it
  # as it walks documents, so the example has to serialize something first.
  # That is the whole point of the file -- it indexes what the other files say,
  # and is kept out of them so a rename rewrites one file instead of every file
  # that mentions the renamed thing.
  it 'ids.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      issue, substitutions = build_snapshot_issue
      serializer.to_yaml(issue)

      expect_snapshot_or_regenerate!(
        'ids.yml',
        serializer.to_yaml_identities(serializer.identities),
        substitutions.except(:web_url))
    end
  end

  # Built through OC::WorkItems.labels_for / .milestones_for rather than from a
  # handed-in list, so the snapshot pins the scoping rule -- project plus every
  # ancestor group -- and not just the serializer's output shape.
  it 'labels.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      project, substitutions = build_snapshot_catalogs

      expect_snapshot_or_regenerate!(
        'labels.yml',
        serializer.to_yaml_catalog(project, :labels, OC::WorkItems.labels_for(project)),
        substitutions)
    end
  end

  it 'milestones.yml matches the committed snapshot' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      project, substitutions = build_snapshot_catalogs

      expect_snapshot_or_regenerate!(
        'milestones.yml',
        serializer.to_yaml_catalog(project, :milestones, OC::WorkItems.milestones_for(project)),
        substitutions)
    end
  end

  it 'round-trips complex markdown through YAML unchanged' do
    travel_to(WorkItemSnapshots::SNAPSHOT_TIME) do
      issue, = build_snapshot_issue

      hash = YAML.safe_load(serializer.to_yaml(issue))

      expect(hash['description']).to eq(WorkItemSnapshots::SNAPSHOT_DESCRIPTION)
      expect(hash['notes'].first['note']).to eq(WorkItemSnapshots::SNAPSHOT_AUTHOR_NOTE)
    end
  end
end
