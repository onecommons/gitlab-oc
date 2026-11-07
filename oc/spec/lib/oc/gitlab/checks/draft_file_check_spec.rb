# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Gitlab::Checks::DraftFileCheck, feature_category: :source_code_management do
  let(:user) { create(:user) }
  let(:project) { create(:project, :repository, :private) }
  let(:user_access) { Gitlab::UserAccess.new(user, container: project) }
  let(:branch) { OC::WorkItems::SYNC_BRANCH }
  let(:uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:inbox) { "#{uuid}/_incoming" }
  let(:logger) { Gitlab::Checks::TimedLogger.new(timeout: Gitlab::GitAccess::INTERNAL_TIMEOUT) }

  before do
    project.add_maintainer(user)
    allow(Gitlab::CurrentSettings).to receive(:uuid).and_return(uuid)
  end

  def check(oldrev:, newrev:, ref: "refs/heads/#{branch}")
    change_access = Gitlab::Checks::SingleChangeAccess.new(
      { oldrev: oldrev, newrev: newrev, ref: ref },
      project: project, user_access: user_access, protocol: 'ssh', logger: logger)

    described_class.new(change_access)
  end

  def draft(title: 'T', **extra)
    { '_schema' => 'issue_draft@1', 'title' => title }.merge(extra.transform_keys(&:to_s)).to_yaml
  end

  # A branch to update, since creation is exempt.
  def seed
    @seed ||= begin
      project.repository.create_file(user, "#{uuid}/ids.yml", "---\n", message: 'seed', branch_name: branch)
      project.repository.commit(branch).sha
    end
  end

  def commit(files, delete: [])
    actions = files.map do |path, content|
      { action: project.repository.blob_at(branch, path) ? :update : :create, file_path: path, content: content }
    end
    actions += delete.map { |path| { action: :delete, file_path: path } }

    project.repository.commit_files(user, branch_name: branch, message: 'drafts', actions: actions)
    project.repository.commit(branch).sha
  end

  def refusal(files)
    old = seed
    new = commit(files)

    check(oldrev: old, newrev: new).validate!
    nil
  rescue Gitlab::GitAccess::ForbiddenError => error
    error.message
  end

  it 'accepts valid drafts, including ones referencing each other' do
    expect(refusal(
      "#{inbox}/a.yml" => draft(description: 'see #draft:b'),
      "#{inbox}/b.yaml" => draft(description: 'see #draft:a')
    )).to be_nil
  end

  it 'refuses a malformed draft, naming the file and line' do
    expect(refusal("#{inbox}/a.yml" => "_schema: issue_draft@1\ntitel: T\n"))
      .to match(%r{\AWork items sync: #{inbox}/a\.yml:2: unknown key "titel"})
  end

  it 'refuses a draft name that is not a valid key' do
    expect(refusal("#{inbox}/Fix Login.yml" => draft)).to include('"Fix Login" is not a valid draft name')
  end

  it 'refuses .yml and .yaml drafts with the same key' do
    expect(refusal("#{inbox}/a.yml" => draft, "#{inbox}/a.yaml" => draft))
      .to include('.yml and .yaml name the same draft')
  end

  it 'ignores files that are not drafts' do
    expect(refusal("#{inbox}/README.md" => 'not yaml: [', "#{inbox}/sub/x.yml" => 'nope: [')).to be_nil
  end

  it 'refuses a larger-than-limit draft' do
    expect(refusal("#{inbox}/a.yml" => draft(description: 'x' * 70.kilobytes))).to include('larger than 64 KiB')
  end

  describe 'references' do
    it 'refuses a #draft: key that is nowhere' do
      expect(refusal("#{inbox}/a.yml" => draft(description: 'see #draft:nope')))
        .to include('#draft:nope names no draft in this push')
    end

    it 'accepts a key an issue was already created from' do
      create(:oc_work_item_draft, project: project, key: 'earlier')

      expect(refusal("#{inbox}/a.yml" => draft(description: 'see #draft:earlier'))).to be_nil
    end

    it 'accepts a key whose draft is still waiting on the branch from an earlier push' do
      old = seed
      commit({ "#{inbox}/waiting.yml" => draft })
      mid = project.repository.commit(branch).sha
      new = commit({ "#{inbox}/a.yml" => draft(description: 'see #draft:waiting') })

      expect { check(oldrev: mid, newrev: new).validate! }.not_to raise_error
      expect(old).to be_present
    end
  end

  describe 'confidential' do
    it 'accepts it on a private project' do
      expect(refusal("#{inbox}/a.yml" => draft(confidential: true))).to be_nil
    end

    it 'refuses it on a public project' do
      project.update!(visibility_level: Gitlab::VisibilityLevel::PUBLIC)

      expect(refusal("#{inbox}/a.yml" => draft(confidential: true)))
        .to include('"confidential: true" is only allowed on private projects')
    end
  end

  it 'checks another installation\'s drafts for form only' do
    other = 'ffffffff-2222-3333-4444-555555555555/_incoming'
    project.update!(visibility_level: Gitlab::VisibilityLevel::PUBLIC)

    expect(refusal("#{other}/a.yml" => draft(confidential: true, description: '#draft:unknown'))).to be_nil
    expect(refusal("#{other}/b.yml" => "_schema: nope\n")).to include("#{other}/b.yml")
  end

  it 'never refuses a deletion' do
    old = seed
    commit({ "#{inbox}/a.yml" => draft })
    mid = project.repository.commit(branch).sha
    new = commit({}, delete: ["#{inbox}/a.yml"])

    expect { check(oldrev: mid, newrev: new).validate! }.not_to raise_error
    expect(old).to be_present
  end

  it 'ignores pushes to other branches, and branch creation' do
    old = seed
    new = commit({ "#{inbox}/a.yml" => "bad: [\n" })

    expect { check(oldrev: old, newrev: new, ref: 'refs/heads/main').validate! }.not_to raise_error
    expect { check(oldrev: Gitlab::Git::SHA1_BLANK_SHA, newrev: new).validate! }.not_to raise_error
  end
end
