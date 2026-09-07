# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Gitlab::Checks::SyncFileCheck, feature_category: :source_code_management do
  let(:user) { create(:user) }
  let(:project) { create(:project, :repository) }
  let(:user_access) { Gitlab::UserAccess.new(user, container: project) }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:path) { OC::WorkItems::SyncFile::PATH }
  let(:logger) { Gitlab::Checks::TimedLogger.new(timeout: Gitlab::GitAccess::INTERNAL_TIMEOUT) }

  let(:valid) do
    <<~YAML
      ---
      _schema: sync@1
      staging:
        uuid: 1111-2222
      prod:
        uuid: 3333-4444
        sync:
          staging:
            import: all
    YAML
  end

  before do
    project.add_maintainer(user)
  end

  # The push as the hook sees it: what the branch was, and what it would become.
  def check(oldrev:, newrev:, ref: "refs/heads/#{branch}")
    change_access = Gitlab::Checks::SingleChangeAccess.new(
      { oldrev: oldrev, newrev: newrev, ref: ref },
      project: project, user_access: user_access, protocol: 'ssh', logger: logger)

    described_class.new(change_access)
  end

  def commit_file(content, message: 'edit sync.yml')
    action = project.repository.blob_at(branch, path) ? :update : :create

    project.repository.commit_files(
      user, branch_name: branch, message: message,
      actions: [{ action: action, file_path: path, content: content }])

    project.repository.commit(branch).sha
  end

  # A branch with a good file on it, so that what follows is an *update*, which
  # is what the check looks at.
  def start_with(content)
    project.repository.create_file(
      user, "#{OC::WorkItems::RecordSerializer::IDENTITIES_KEY}.yml", "---\n",
      message: 'seed', branch_name: branch)

    commit_file(content)
  end

  describe '#validate!' do
    it 'accepts a push that leaves the file valid' do
      old = start_with(valid)
      new = commit_file(valid.sub('import: all', 'import: transferred'))

      expect { check(oldrev: old, newrev: new).validate! }.not_to raise_error
    end

    # Announced the same way an accepted push is: by the time this reaches
    # anybody it already carries git's `remote:` and Gitaly's `GitLab:`, and
    # neither of those says which part of the system is talking.
    it 'rejects a push that breaks it, and says where' do
      old = start_with(valid)
      new = commit_file(valid.sub('import: all', 'improt: all'))

      expect { check(oldrev: old, newrev: new).validate! }.to raise_error(
        Gitlab::GitAccess::ForbiddenError,
        /\AWork items sync: sync\.yml:\d+: unknown key "improt"/)
    end

    it 'reports a structural conflict the file alone can settle' do
      old = start_with(valid)
      new = commit_file(<<~YAML)
        ---
        _schema: sync@1
        staging:
          uuid: 1111-2222
          sync:
            prod:
              transfer: all
        prod:
          uuid: 3333-4444
      YAML

      expect { check(oldrev: old, newrev: new).validate! }
        .to raise_error(Gitlab::GitAccess::ForbiddenError, /declares no "import"/)
    end

    it 'accepts deleting the file, which declares nothing rather than being wrong' do
      old = start_with(valid)
      project.repository.delete_file(user, path, message: 'no thanks', branch_name: branch)
      new = project.repository.commit(branch).sha

      expect { check(oldrev: old, newrev: new).validate! }.not_to raise_error
    end

    # Cheap, and it means a project pushing this branch a hundred times a day
    # pays nothing for a file nobody is editing.
    it 'does not look at a push that leaves the file alone' do
      old = start_with(valid)
      project.repository.create_file(
        user, '1111-2222/issues/1.yml', "---\n",
        message: 'unrelated', branch_name: branch)
      new = project.repository.commit(branch).sha

      expect(OC::WorkItems::SyncFile).not_to receive(:parse)

      check(oldrev: old, newrev: new).validate!
    end

    it 'ignores every other branch' do
      old = project.repository.commit('master').sha
      new = project.repository.create_file(
        user, path, 'nonsense: [', message: 'not the sync branch', branch_name: 'master')

      expect { check(oldrev: old, newrev: new, ref: 'refs/heads/master').validate! }
        .not_to raise_error
    end

    it 'ignores a deletion of the branch' do
      old = start_with(valid)

      expect { check(oldrev: old, newrev: Gitlab::Git::SHA1_BLANK_SHA).validate! }.not_to raise_error
    end

    # The invariant that keeps the check from destroying what it protects.
    # purge_own_history! deletes the branch and re-commits every foreign file
    # into a fresh orphan, sync.yml included. If that replay could be refused,
    # it would fail with the branch already gone and take every peer directory
    # with it.
    it 'leaves the creation of the branch alone, however bad the file is' do
      new = project.repository.create_file(
        user, path, "---\n_schema: nope\n", message: 'replay', branch_name: branch)

      expect { check(oldrev: Gitlab::Git::SHA1_BLANK_SHA, newrev: new).validate! }.not_to raise_error
    end

    it 'refuses a file too large to be one somebody wrote' do
      old = start_with(valid)
      new = commit_file("#{valid}.padding: #{'x' * described_class::MAX_BYTES}\n")

      expect { check(oldrev: old, newrev: new).validate! }
        .to raise_error(Gitlab::GitAccess::ForbiddenError, /larger than/)
    end
  end

  # The seam: every push runs this alongside the upstream ref-level checks.
  describe 'wiring' do
    it 'is run by SingleChangeAccess' do
      old = start_with(valid)
      new = commit_file(valid.sub('import: all', 'improt: all'))

      access = Gitlab::Checks::SingleChangeAccess.new(
        { oldrev: old, newrev: new, ref: "refs/heads/#{branch}" },
        project: project, user_access: user_access, protocol: 'ssh', logger: logger)

      expect { access.validate! }
        .to raise_error(Gitlab::GitAccess::ForbiddenError, /sync\.yml/)
    end
  end
end
