# frozen_string_literal: true

require 'spec_helper'

# What a push of sync.yml actually says back to the person who pushed it.
#
# The unit specs stop at the exception: OC::Gitlab::Checks::SyncFileCheck raises a
# ForbiddenError with the right message, and SingleChangeAccess runs it. That
# leaves the two hops between there and the pusher untested, and they are where
# a message gets lost rather than mangled -- the internal API has to answer 401
# rather than 403, because on a 403 the custom message is dropped and replaced
# with the generic "API is not accessible", and post-receive has to carry its
# messages in the response body at all.
#
# Past this point nothing is ours: Gitaly prefixes the message with "GitLab: "
# and git prefixes every line with "remote: ", both in their own code.
RSpec.describe 'pushing the work items sync file', feature_category: :source_code_management do
  include APIInternalBaseHelpers

  let_it_be(:owner) { create(:user, :with_namespace) }
  let_it_be(:developer) { create(:user) }
  let_it_be(:owner_key) { create(:key, user: owner) }
  let_it_be(:developer_key) { create(:key, user: developer) }

  # let, not let_it_be: the repository is Gitaly state and does not roll back
  # with the database, so a shared project would carry one example's branch
  # into the next and every seed after the first would collide.
  let(:project) { create(:project, :repository, namespace: owner.namespace) }

  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:path) { OC::WorkItems::SyncFile::PATH }
  let(:instance_uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:peer_uuid) { '99999999-8888-7777-6666-555555555555' }

  let(:valid) do
    <<~YAML
      ---
      _schema: sync@1
      them:
        uuid: #{peer_uuid}
      us:
        uuid: #{instance_uuid}
        sync:
          them:
            import: all
    YAML
  end

  before do
    stub_const('Gitlab::QueryLimiting::Transaction::THRESHOLD', 200)
    allow(::Gitlab::CurrentSettings).to receive(:uuid).and_return(instance_uuid)
    project.add_developer(developer)
  end

  # Puts the file on the branch and returns the change this push represents,
  # in the form gitlab-shell sends it.
  def commit_sync_file(content, message: 'edit sync.yml')
    oldrev = project.repository.commit(branch)&.sha || Gitlab::Git::SHA1_BLANK_SHA
    action = project.repository.blob_at(branch, path) ? :update : :create

    project.repository.commit_files(
      owner, branch_name: branch, message: message,
      actions: [{ action: action, file_path: path, content: content }])

    "#{oldrev} #{project.repository.commit(branch).sha} refs/heads/#{branch}"
  end

  # A branch that already exists, so that what follows is an update -- which is
  # what the check looks at.
  def start_branch
    project.repository.create_file(
      owner, "#{peer_uuid}/ids.yml", "---\n", message: 'seed', branch_name: branch)
  end

  describe 'POST /internal/allowed' do
    before do
      start_branch
    end

    it 'refuses the push, and hands back the reason to show the pusher' do
      changes = commit_sync_file(valid.sub('import: all', 'improt: all'))

      push(owner_key, project, changes: changes)

      # 401 rather than 403 on purpose: the API comments that a 403 has the
      # custom message dropped, and the pusher is shown "API is not
      # accessible" instead of anything useful.
      expect(response).to have_gitlab_http_status(:unauthorized)
      expect(json_response['status']).to be(false)

      # Announced the same way a successful push is, because by the time
      # anyone reads it the line already carries git's `remote:` and Gitaly's
      # `GitLab:`, and neither of those says anything about work items.
      expect(json_response['message']).to match(
        %r{\AWork items sync: sync\.yml:\d+: unknown key "improt" in "us/sync/them"})
    end

    it 'allows a push that leaves the file valid' do
      changes = commit_sync_file(valid.sub('import: all', 'import: transferred'))

      push(owner_key, project, changes: changes)

      expect(response).to have_gitlab_http_status(:ok)
      expect(json_response['status']).to be(true)
    end

    it 'allows a push that does not touch the file at all' do
      project.repository.create_file(
        owner, "#{peer_uuid}/issues/1.yml", "---\n", message: 'unrelated', branch_name: branch)

      push(owner_key, project)

      expect(response).to have_gitlab_http_status(:ok)
    end
  end

  describe 'POST /internal/post_receive' do
    let(:changes) { commit_sync_file(valid) }

    # key_id is how gitlab-shell names the pusher, and it is what decides
    # whether this push can authorize an import. Leaving it out makes the
    # pusher nobody, which is a different case entirely.
    def post_receive(as: owner_key, pushing: changes)
      post api('/internal/post_receive'),
        params: {
          gl_repository: gl_repository_for(project), changes: pushing, key_id: as.id
        },
        headers: gitlab_shell_internal_api_request_header
    end

    # Ours, out of whatever else the push has to say -- a first push of a
    # branch also offers to open a merge request for it.
    def sync_message
      json_response['messages'].find do |entry|
        entry['message'].start_with?(OC::PostReceiveService::PREFIX)
      end
    end

    before do
      start_branch
    end

    it 'says what the file it just accepted is going to do' do
      post_receive

      expect(response).to have_gitlab_http_status(:ok)
      expect(sync_message).to match(
        'message' => a_string_including("This instance is 'us'").and(
          a_string_including('imports all from them')),
        'type' => 'basic')
    end

    # The mistake that survives parsing and is invisible without this: a file
    # that is entirely valid and simply describes somebody else.
    context 'when the file names no instance with our uuid' do
      let(:changes) { commit_sync_file(valid.sub(instance_uuid, 'somebody-else')) }

      it 'warns that nothing here will be imported' do
        post_receive

        expect(sync_message).to match(
          'message' => a_string_including('names no instance with this one').and(
            a_string_including(instance_uuid)),
          'type' => 'alert')
      end
    end

    # The other silent one: the file is right, and the push cannot act on it.
    it 'warns a pusher who cannot authorize an import' do
      post_receive(as: developer_key)

      expect(sync_message).to match(
        'message' => a_string_including('Only a push by an Owner'), 'type' => 'alert')
    end

    # The push-time check leaves branch creation alone so that a purge replay
    # can never be refused, which is the one way a broken file lands. Saying so
    # here is the only feedback anybody gets for it.
    context 'when a broken file arrives by creating the branch' do
      let(:changes) do
        project.repository.delete_refs("refs/heads/#{branch}")
        project.repository.expire_branches_cache

        commit_sync_file("---\n_schema: sync@1\nus:\n  sync: {}\n", message: 'replay')
      end

      it 'says why nothing will be imported' do
        post_receive

        expect(sync_message).to match(
          'message' => a_string_including('has no "uuid"').and(
            a_string_including('Nothing will be imported')),
          'type' => 'alert')
      end
    end

    # Every push of this branch runs through here, and most of them are the
    # sync writing its own files. Only an edit to the control file is worth a
    # word.
    it 'says nothing when the push leaves the file alone' do
      commit_sync_file(valid)
      before_sha = project.repository.commit(branch).sha
      after_sha = project.repository.create_file(
        owner, "#{peer_uuid}/issues/2.yml", "---\n", message: 'unrelated', branch_name: branch)

      post_receive(pushing: "#{before_sha} #{after_sha} refs/heads/#{branch}")

      expect(sync_message).to be_nil
    end

    it 'says nothing about a push to any other branch' do
      post_receive(pushing: "#{Gitlab::Git::SHA1_BLANK_SHA} #{project.commit.sha} refs/heads/master")

      expect(sync_message).to be_nil
    end
  end
end
