# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Projects::RecordCloudmapEventWorker, feature_category: :source_code_management do
  let_it_be(:project) { create(:project, :public) }

  let(:event) do
    ::Projects::ProjectVisibilityChangedEvent.new(data: {
      project_id: project.id,
      namespace_id: project.namespace_id,
      root_namespace_id: project.root_ancestor.id,
      visibility_level: ::Gitlab::VisibilityLevel::PRIVATE
    })
  end

  it_behaves_like 'subscribes to event'

  describe 'a visibility change' do
    it 'records the new level' do
      expect { consume_event(subscriber: described_class, event: event) }
        .to change { OC::Projects::CloudmapEvent.count }.by(1)

      record = OC::Projects::CloudmapEvent.last
      expect(record).to be_visibility_changed
      expect(record.project_path).to eq(project.full_path)
      expect(record.payload)
        .to eq('visibility' => 'private', 'web_url' => project.web_url)
    end

    # The event can outlive the project when a deletion follows closely enough.
    it 'does nothing when the project is already gone' do
      allow(::Project).to receive(:find_by_id).and_return(nil)

      expect { consume_event(subscriber: described_class, event: event) }
        .not_to change { OC::Projects::CloudmapEvent.count }
    end
  end

  describe 'a finished pipeline' do
    let_it_be(:pipeline) { create(:ci_pipeline, project: project, status: :success) }

    def pipeline_event(status)
      ::Ci::PipelineFinishedEvent.new(data: {
        pipeline_id: pipeline.id, status: status,
        source: 'push', partition_id: pipeline.partition_id
      })
    end

    # The event names no project, so the pipeline is what supplies one.
    it 'records the run against the pipeline\'s project' do
      expect { consume_event(subscriber: described_class, event: pipeline_event('success')) }
        .to change { OC::Projects::CloudmapEvent.count }.by(1)

      record = OC::Projects::CloudmapEvent.last
      expect(record).to be_pipeline_finished
      expect(record.project_path).to eq(project.full_path)
      expect(record.payload).to eq(
        'visibility' => 'public', 'status' => 'success', 'source' => 'push',
        'pipeline_id' => pipeline.id,
        'web_url' => ::Gitlab::Routing.url_helpers.project_pipeline_url(project, pipeline))
    end

    # Deliberately unfiltered, unlike the fork's other subscribers to this
    # event: a run's status is a property the cloudmap records.
    it 'records a failed run too' do
      expect { consume_event(subscriber: described_class, event: pipeline_event('failed')) }
        .to change { OC::Projects::CloudmapEvent.count }.by(1)

      expect(OC::Projects::CloudmapEvent.last.payload['status']).to eq('failed')
    end

    it 'does nothing when the pipeline cannot be found' do
      event = ::Ci::PipelineFinishedEvent.new(data: {
        pipeline_id: non_existing_record_id, status: 'success',
        source: 'push', partition_id: pipeline.partition_id
      })

      expect { consume_event(subscriber: described_class, event: event) }
        .not_to change { OC::Projects::CloudmapEvent.count }
    end
  end

  describe 'a published package' do
    let_it_be(:package) { create(:generic_package, project: project) }

    let(:package_event) do
      ::Packages::PackageCreatedEvent.new(data: {
        project_id: project.id, id: package.id, name: package.name,
        version: package.version, package_type: package.package_type
      })
    end

    # The whole record travels in the payload, so a consumer needs no call
    # back to GitLab for it.
    it 'records what the package is' do
      expect { consume_event(subscriber: described_class, event: package_event) }
        .to change { OC::Projects::CloudmapEvent.count }.by(1)

      record = OC::Projects::CloudmapEvent.last
      expect(record).to be_package_published
      expect(record.payload).to eq(
        'package_id' => package.id, 'name' => package.name,
        'version' => package.version, 'package_type' => 'generic',
        'visibility' => 'public', 'packages_public' => true,
        'web_url' => ::Gitlab::Routing.url_helpers.project_package_url(project, package.id))
    end

    # Whether anyone may pull is a separate question from the project's
    # visibility, and it is asked of the policy rather than derived -- so what
    # is checked here is that the answer reaches the payload, not the policy's
    # own table, which is upstream's to guarantee.
    it 'records what the policy says' do
      allow(::Users::Anonymous).to receive(:can?)
        .with(:read_package, anything).and_return(false)

      consume_event(subscriber: described_class, event: package_event)

      expect(OC::Projects::CloudmapEvent.last.payload)
        .to include('visibility' => 'public', 'packages_public' => false)
    end

    # The two corners where ProjectFeature#public_packages? answers wrongly,
    # kept as real cases because the cloudmap depends on them: a private
    # project that opened its registry is pullable, and the instance setting
    # is the other half of that grant. Each builds its own project, since
    # let_it_be freezes the shared one.
    it 'records a private project that opened its registry as pullable' do
      expect(payload_for(::ProjectFeature::PUBLIC))
        .to include('visibility' => 'private', 'packages_public' => true)
    end

    it 'records it as not pullable when the instance forbids anonymous pulls' do
      stub_application_setting(package_registry_allow_anyone_to_pull_option: false)

      expect(payload_for(::ProjectFeature::PUBLIC)).to include('packages_public' => false)
    end

    def payload_for(registry_access_level)
      project = create(:project, :private)
      project.project_feature.update!(package_registry_access_level: registry_access_level)
      package = create(:generic_package, project: project)

      consume_event(subscriber: described_class, event: ::Packages::PackageCreatedEvent.new(data: {
        project_id: project.id, id: package.id, name: package.name,
        version: package.version, package_type: package.package_type
      }))

      OC::Projects::CloudmapEvent.last.payload
    end
  end

  describe 'a registry change' do
    def image_payload(action, **extra)
      consume_event(subscriber: described_class,
        event: ::OC::ContainerRegistry::ImageChangedEvent.new(data: {
          project_id: project.id, action: action,
          repository: project.full_path, **extra
        }))

      OC::Projects::CloudmapEvent.last
    end

    before do
      stub_container_registry_config(enabled: true, host_port: 'registry.test')
    end

    it 'records a push with the pull reference a consumer would use' do
      record = image_payload('pushed', tag: 'latest', digest: 'sha256:abc')

      expect(record).to be_image_pushed
      expect(record.payload).to include(
        'repository' => project.full_path, 'tag' => 'latest', 'digest' => 'sha256:abc',
        'image' => "registry.test/#{project.full_path}:latest",
        'web_url' => ::Gitlab::Routing.url_helpers.project_container_registry_index_url(project))
    end

    # A tag going and the image going are different facts; a consumer that
    # could not tell them apart would drop a record on a retag.
    it 'separates a tag delete from a manifest delete' do
      expect(image_payload('tag_deleted', tag: 'latest')).to be_image_tag_deleted
      expect(image_payload('deleted', digest: 'sha256:abc')).to be_image_deleted
    end

    # No tag, so nothing a consumer could pull.
    it 'omits the pull reference from a manifest delete' do
      expect(image_payload('deleted', digest: 'sha256:abc').payload).not_to have_key('image')
    end

    # An unknown action never reaches the worker: the event's own schema enums
    # the three, so it is refused at construction. The worker keeps a guard for
    # the day that enum grows, but this is where the contract is enforced.
    it 'refuses an action outside the schema' do
      data = { project_id: project.id, action: 'scanned', repository: project.full_path }

      expect { ::OC::ContainerRegistry::ImageChangedEvent.new(data: data) }
        .to raise_error(::Gitlab::EventStore::InvalidEvent, /action/)
    end
  end

  describe 'a mirror sync' do
    it 'records the ref that moved' do
      consume_event(subscriber: described_class,
        event: ::OC::Repositories::MirrorSyncedEvent.new(data: {
          project_id: project.id, ref: 'main',
          old_sha: 'a' * 40, new_sha: 'b' * 40
        }))

      record = OC::Projects::CloudmapEvent.last
      expect(record).to be_mirror_synced
      expect(record.payload).to include(
        'ref' => 'main', 'old_sha' => 'a' * 40, 'new_sha' => 'b' * 40,
        'visibility' => 'public', 'web_url' => project.web_url)
    end

    # A branch the mirror created here for the first time.
    it 'records a new ref with no old sha' do
      consume_event(subscriber: described_class,
        event: ::OC::Repositories::MirrorSyncedEvent.new(data: {
          project_id: project.id, ref: 'new-branch', new_sha: 'b' * 40
        }))

      expect(OC::Projects::CloudmapEvent.last.payload).not_to have_key('old_sha')
    end
  end
end
