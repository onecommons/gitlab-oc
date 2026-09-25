# frozen_string_literal: true

require 'spec_helper'

# The override lives on OC::ContainerRegistry::Event and is only reachable
# through the upstream class it is prepended onto.
RSpec.describe OC::ContainerRegistry::Event, :clean_gitlab_redis_shared_state,
  feature_category: :container_registry do
  let_it_be(:project) { create(:project) }

  let(:repository_path) { project.full_path }
  let(:target) { { 'mediaType' => 'application/vnd.docker.distribution.manifest.v2+json' } }
  let(:raw_event) { { 'action' => action, 'target' => target.merge('repository' => repository_path) } }

  subject(:handle) { ::ContainerRegistry::Event.new(raw_event).handle! }

  before do
    stub_container_registry_config(enabled: true, api_url: 'http://registry.test', host_port: 'registry.test')
  end

  describe 'a push' do
    let(:action) { 'push' }

    context 'with a tag' do
      let(:target) { super().merge('tag' => 'latest', 'digest' => 'sha256:abc') }

      it 'publishes an image change' do
        expect { handle }
          .to publish_event(::OC::ContainerRegistry::ImageChangedEvent)
          .with(project_id: project.id, action: 'pushed',
            repository: repository_path, tag: 'latest', digest: 'sha256:abc')
      end
    end

    # One `docker push` notifies once per blob as well, and only the manifest
    # notification carries the tag -- so a tagless push must publish nothing or
    # a five-layer image becomes five rows.
    context 'without a tag' do
      let(:target) { super().merge('digest' => 'sha256:abc') }

      it 'publishes nothing' do
        expect { handle }.not_to publish_event(::OC::ContainerRegistry::ImageChangedEvent)
      end
    end
  end

  describe 'a delete' do
    let(:action) { 'delete' }

    context 'with a tag' do
      let(:target) { super().merge('tag' => 'latest') }

      it 'reports the reference going, not the image' do
        expect { handle }
          .to publish_event(::OC::ContainerRegistry::ImageChangedEvent)
          .with(project_id: project.id, action: 'tag_deleted', repository: repository_path, tag: 'latest')
      end
    end

    context 'with a digest and no tag' do
      let(:target) { super().merge('digest' => 'sha256:abc') }

      it 'reports the image itself going' do
        expect { handle }
          .to publish_event(::OC::ContainerRegistry::ImageChangedEvent)
          .with(project_id: project.id, action: 'deleted',
            repository: repository_path, digest: 'sha256:abc')
      end
    end
  end

  context 'when the path names no project here' do
    let(:action) { 'push' }
    let(:repository_path) { 'nobody/nothing' }
    let(:target) { super().merge('tag' => 'latest') }

    it 'publishes nothing' do
      expect { handle }.not_to publish_event(::OC::ContainerRegistry::ImageChangedEvent)
    end
  end
end
