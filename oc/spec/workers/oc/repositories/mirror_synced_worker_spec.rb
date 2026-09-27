# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Repositories::MirrorSyncedWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  let(:event) do
    OC::Repositories::MirrorSyncedEvent.new(data: {
      project_id: project.id, ref: 'main', old_sha: 'a' * 40, new_sha: 'b' * 40
    })
  end

  it_behaves_like 'subscribes to event'

  it 'asks the Unfurl server to re-read the files the sync changed, as a push would' do
    expect(OC::Repositories::ProjectUnfurlCacheWorker)
      .to receive(:perform_async).with(project.id, 'refs/heads/main', 'a' * 40, 'b' * 40)

    consume_event(subscriber: described_class, event: event)
  end

  # A branch the mirror created here has nothing to diff against, which the
  # cache worker reads from a blank oldrev.
  it 'passes a blank oldrev for a branch that is new here' do
    new_branch = OC::Repositories::MirrorSyncedEvent.new(data: {
      project_id: project.id, ref: 'feature', new_sha: 'b' * 40
    })

    expect(OC::Repositories::ProjectUnfurlCacheWorker)
      .to receive(:perform_async).with(project.id, 'refs/heads/feature', Gitlab::Git::SHA1_BLANK_SHA, 'b' * 40)

    consume_event(subscriber: described_class, event: new_branch)
  end

  it 'refreshes the caches classification reads, without statistics' do
    expect(ProjectCacheWorker)
      .to receive(:perform_async).with(project.id, %w[ensemble_template_yaml unfurl_yaml], [], false)

    consume_event(subscriber: described_class, event: event)
  end
end
