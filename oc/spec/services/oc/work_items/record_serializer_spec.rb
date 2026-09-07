# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/helpers/work_item_sync_paths'

RSpec.describe OC::WorkItems::RecordSerializer, feature_category: :source_code_management do
  include WorkItemSyncPaths

  let_it_be(:user) { create(:user) }
  let_it_be(:project) { create(:project, :private) }
  let_it_be(:label) { create(:label, project: project, title: 'bug') }

  subject(:serializer) { described_class.new }

  describe '#serialize' do
    let_it_be(:issue) do
      create(:labeled_issue, project: project, author: user, labels: [label]).tap do |issue|
        create(:note, noteable: issue, project: project, note: 'a comment')
        create(:award_emoji, awardable: issue, name: 'thumbsup')
      end
    end

    it 'produces the import/export document plus web_url' do
      hash = serializer.serialize(issue)

      expect(hash['iid']).to eq(issue.iid)
      expect(hash['title']).to eq(issue.title)
      expect(hash['state']).to eq('opened')
      expect(hash['author_id']).to eq(user.id)
      expect(hash['label_links'].first['label']['title']).to eq('bug')
      expect(hash['notes'].first['note']).to eq('a comment')
      expect(hash['award_emoji'].first['name']).to eq('thumbsup')
      expect(hash['web_url']).to eq(Gitlab::UrlBuilder.build(issue))
    end

    it 'does not export DB ids' do
      hash = serializer.serialize(issue)

      expect(hash).not_to have_key('id')
      expect(hash['notes'].first).not_to have_key('id')
    end

    it 'leads with a schema header naming the import/export relation' do
      hash = serializer.serialize(issue)

      expect(hash.each_key.first).to eq('_schema')
      # Written out rather than built from the constants: this literal is the
      # format, and a spec that reassembles it could not notice it changing.
      expect(hash['_schema']).to eq('issues@1')
    end

    # Nothing upstream controls belongs here. If the import/export version were
    # in the header, a GitLab release that changed a relation we do not even
    # sync would change the first line of every file and rewrite the whole
    # branch; it goes in the commit trailer instead.
    it 'keeps the header free of the import/export version' do
      expect(serializer.serialize(issue)['_schema']).not_to include(Gitlab::ImportExport::VERSION)
    end

    it 'writes a schema header a consumer can take apart again' do
      match = described_class::SCHEMA_PATTERN.match(serializer.serialize(issue)['_schema'])

      expect(match[:type]).to eq('issues')
      expect(match[:version]).to eq(described_class::SCHEMA_VERSION.to_s)
    end

    it 'attributes each note to its own author' do
      commenter = create(:user, name: 'Second Participant')
      discussion = create(:issue, project: project, author: user)
      create(:note, noteable: discussion, project: project, author: user, note: 'from the reporter')
      create(:note, noteable: discussion, project: project, author: commenter, note: 'from someone else')

      notes = serializer.serialize(discussion.reload)['notes'].index_by { |n| n['note'] }

      expect(notes['from the reporter']['author_id']).to eq(user.id)
      expect(notes['from someone else']['author_id']).to eq(commenter.id)
      # the embedded name is what survives an import into another instance,
      # where the author id may not resolve to the same user
      expect(notes['from someone else']['author']['name']).to eq('Second Participant')
    end

    it 'serializes system notes with their metadata' do
      note = create(:note, :system, noteable: issue, project: project)
      create(:system_note_metadata, note: note, action: 'label')

      metadata = serializer.serialize(issue.reload)['notes']
        .find { |n| n['system'] }&.dig('system_note_metadata')

      expect(metadata['action']).to eq('label')
    end

    # The export schema keeps four of SystemNoteMetadata's seven columns: `id`
    # and `note_id` are structural, and `description_version_id` is dropped
    # upstream, so a "changed the description" note keeps its action but loses
    # the link to the stored before/after versions.
    it 'keeps every system note metadata attribute the export schema defines' do
      note = create(:note, :system, noteable: issue, project: project)
      create(:system_note_metadata, note: note, action: 'commit', commit_count: 3)

      metadata = serializer.serialize(issue.reload)['notes']
        .find { |n| n.dig('system_note_metadata', 'action') == 'commit' }['system_note_metadata']

      expect(metadata.keys).to match_array(%w[action commit_count created_at updated_at])
      expect(metadata['commit_count']).to eq(3)
    end

    # Labels and milestones are embedded per record rather than referenced, and
    # the embedded copy carries group_id and type. Nothing about the issue
    # document is project-scoped, so a group label or group milestone survives
    # in full -- no schema change is needed to capture them.
    it 'embeds group-scoped labels and milestones together with their group' do
      group = create(:group)
      grouped_project = create(:project, :private, group: group)
      group_label = create(:group_label, group: group, title: 'group-bug')
      group_milestone = create(:milestone, group: group, title: 'group-15.11')
      issue = create(:labeled_issue,
        project: grouped_project, labels: [group_label], milestone: group_milestone)

      hash = serializer.serialize(issue.reload)

      label = hash['label_links'].first['label']
      expect(label['title']).to eq('group-bug')
      expect(label['type']).to eq('GroupLabel')
      expect(label['group_id']).to eq(group.id)
      expect(label).not_to have_key('project_id')

      expect(hash['milestone']['title']).to eq('group-15.11')
      expect(hash['milestone']['group_id']).to eq(group.id)
      expect(hash['milestone']).not_to have_key('project_id')
    end

    it 'preserves thread structure, giving replies their parent discussion id' do
      top_level = create(:discussion_note_on_issue, noteable: issue, project: project, note: 'top level')
      reply = create(:discussion_note_on_issue, noteable: issue, project: project,
        in_reply_to: top_level, note: 'a reply')
      create(:discussion_note_on_issue, noteable: issue, project: project, note: 'other thread')

      notes = serializer.serialize(issue.reload)['notes'].index_by { |n| n['note'] }

      expect(reply.discussion_id).to eq(top_level.discussion_id)
      expect(notes['a reply']['discussion_id']).to eq(notes['top level']['discussion_id'])
      expect(notes['other thread']['discussion_id']).not_to eq(notes['top level']['discussion_id'])
    end
  end

  describe '#to_yaml' do
    let_it_be(:issue) do
      create(:issue, project: project).tap do |issue|
        create_list(:note, 3, noteable: issue, project: project, created_at: Time.zone.parse('2026-01-01 12:00'))
      end
    end

    it 'is byte-stable across serializer instances' do
      expect(serializer.to_yaml(issue)).to eq(described_class.new.to_yaml(issue.reload))
    end

    it 'round-trips through YAML.safe_load' do
      expect(YAML.safe_load(serializer.to_yaml(issue))).to eq(serializer.serialize(issue))
    end
  end

  # A replica is another instance's item, held here read-only. Serializing its
  # contents would republish them -- this branch would claim an item it only
  # mirrors, and across a mesh of instances the same issue would multiply into
  # a copy per instance, each looking equally original.
  describe 'replicas of another instance' do
    let_it_be_with_reload(:replicated_issue) { create(:issue, project: project, title: 'Held elsewhere') }

    let(:source_path) { '11111111-2222-3333-4444-555555555555/issues/42.yml' }
    let(:source_url) { 'https://peer.example.com/group/project/-/issues/42' }

    before do
      create(:oc_replicated_work_item, project: project, issue: replicated_issue,
        source_path: source_path, source_web_url: source_url)
      replicated_issue.reload
    end

    it 'writes a pointer instead of the item' do
      hash = serializer.serialize(replicated_issue)

      expect(hash).to eq(
        '_schema' => 'issue_reference@1',
        'source_path' => source_path,
        'source_web_url' => source_url,
        'web_url' => Gitlab::UrlBuilder.build(replicated_issue))
    end

    it 'carries none of the content it is standing in for' do
      hash = serializer.serialize(replicated_issue)

      expect(hash).not_to include('title', 'description', 'author_id', 'notes', 'iid')
    end

    # The one thing in the file that cannot be worked out from the branch.
    # Both instances publish an ids.yml, but neither says that their user 12
    # and our user 500 are the same person.
    it 'publishes the correspondence the importer worked out' do
      replicated_issue.oc_replica.update!(
        identities: { 'users' => { 500 => 12, 90 => 7 }, 'projects' => { 77 => 42 } })

      # Integer keys, matching ids.yml. The row stores JSON, where a key can
      # only be a string, so they would otherwise read as '12': here and 12:
      # one file away.
      expect(serializer.serialize(replicated_issue.reload)['ids']).to eq(
        'projects' => { 77 => 42 },
        'users' => { 90 => 7, 500 => 12 })
    end

    # Nothing was matched, so there is no correspondence -- every author is the
    # ghost user. An empty block would suggest one had been looked for and
    # found to be nothing.
    it 'leaves the block out when the importer mapped nobody' do
      expect(serializer.serialize(replicated_issue)).not_to have_key('ids')
    end

    it 'still parses as a schema header, so a reader can refuse what it does not know' do
      match = described_class::SCHEMA_PATTERN.match(
        serializer.serialize(replicated_issue)['_schema'])

      expect(match[:type]).to eq('issue_reference')
      expect(match[:version]).to eq('1')
      expect(described_class.reference?(serializer.serialize(replicated_issue)['_schema'])).to be(true)
    end

    it 'does not mistake an ordinary document for a reference' do
      ordinary = create(:issue, project: project)

      expect(described_class.reference?(serializer.serialize(ordinary)['_schema'])).to be(false)
    end

    it 'leaves out a source URL the row never recorded' do
      replicated_issue.oc_replica.update!(source_web_url: nil)

      expect(serializer.serialize(replicated_issue.reload)).not_to have_key('source_web_url')
    end

    it 'does the same for a merge request' do
      merge_request = create(:merge_request, source_project: project, target_project: project)
      create(:oc_replicated_work_item, :merge_request_kind, project: project,
        merge_request: merge_request, source_path: 'peer/merge_requests/3.yml')

      expect(serializer.serialize(merge_request.reload)['_schema']).to eq('merge_request_reference@1')
    end
  end

  # A row does not always mean "write a pointer". It means this record and some
  # path on the branch are related, and the state says which of four ways.
  describe 'items a transfer has moved' do
    let_it_be_with_reload(:issue) { create(:issue, project: project, title: 'Moved here') }

    let(:source_path) { '11111111-2222-3333-4444-555555555555/issues/42.yml' }

    def row(trait)
      create(:oc_replicated_work_item, trait, project: project, issue: issue,
        source_path: source_path)
      issue.reload
    end

    # The item is ours now, so the branch has to carry it rather than point at
    # somebody else's copy of it -- and at the same path its pointer used to
    # occupy, so the one replaces the other with nothing left behind.
    it 'writes the whole document for an adopted item' do
      hash = serializer.serialize(row(:adopted))

      expect(hash['_schema']).to eq('issues@1')
      expect(hash['title']).to eq('Moved here')
    end

    # The only part of a transfer that travels through the files rather than
    # through anybody's database: it tells the instance that owns that path
    # that it may stop holding the item.
    it 'stamps an adopted document with where the item came from' do
      expect(serializer.serialize(row(:adopted))['transferred_from']).to eq(source_path)
    end

    # Ours all along -- a peer's document turned out to describe an issue that
    # was already here. Nothing about that makes it theirs, so the document is
    # exactly what it would have been without the row.
    it 'writes a plain document for a matched item, with no stamp' do
      hash = serializer.serialize(row(:matched))

      expect(hash['title']).to eq('Moved here')
      expect(hash).not_to have_key('transferred_from')
    end

    # Neither rewritten nor deleted. Deleting it would withdraw the item from
    # every instance mirroring it for as long as the transfer takes, and the
    # transfer can take days.
    it 'leaves a surrendered item file exactly as it is' do
      expect(serializer.serialize(row(:surrendered))).to eq(described_class::LEAVE_ALONE)
      expect(serializer.to_yaml(issue)).to eq(described_class::LEAVE_ALONE)
    end
  end

  describe 'merge requests' do
    let_it_be_with_reload(:merge_request) { create(:merge_request, source_project: project, target_project: project) }

    describe 'the diff' do
      let_it_be(:with_repo) { create(:project, :repository) }
      let_it_be(:real) { create(:merge_request, source_project: with_repo, target_project: with_repo) }

      subject(:diff) { serializer.serialize(real)['merge_request_diff'] }

      it 'keeps the row, and the commit shas that make the diff reproducible' do
        expect(diff['base_commit_sha']).to eq(real.merge_request_diff.base_commit_sha)
        expect(diff['start_commit_sha']).to eq(real.merge_request_diff.start_commit_sha)
        expect(diff['head_commit_sha']).to eq(real.merge_request_diff.head_commit_sha)
        expect(diff['commits_count']).to eq(real.merge_request_diff.commits_count)
      end

      # The patch text and the commit list are the two relations worth an order
      # of magnitude, and both describe code this repository already holds.
      it 'drops the per-file patches and the per-commit rows' do
        expect(diff).not_to have_key('merge_request_diff_files')
        expect(diff).not_to have_key('merge_request_diff_commits')
      end

      it 'drops what background housekeeping moves on its own' do
        described_class::DIFF_HOUSEKEEPING_ATTRIBUTES.each do |attribute|
          expect(diff).not_to have_key(attribute.to_s)
        end
      end

      it 'does not load the diff files it is not going to serialize' do
        preload = serializer.preloads(:merge_requests)

        expect(preload).to have_key(:merge_request_diff)
        expect(preload[:merge_request_diff]).to be_nil
      end

      it 'keeps the merge request method-based shas alongside it' do
        hash = serializer.serialize(real)

        expect(hash['diff_head_sha']).to be_present
        expect(hash['source_branch']).to eq(real.source_branch)
      end
    end

    # Everything null or empty is left out, so a document carries only what it
    # actually says -- about half of a merge request was lines like
    # `merge_error:` before this.
    it 'leaves out keys with nothing in them' do
      hash = serializer.serialize(merge_request)

      expect(hash).not_to have_key('merge_error')
      expect(hash).not_to have_key('merge_commit_sha')
      expect(hash).not_to have_key('merge_request_assignees')
    end

    # Absent and null restore identically -- except where the column's default
    # is not null, and allow_maintainer_to_push defaults to *true*. Dropping it
    # would quietly grant maintainers push access to a fork's branch.
    it 'keeps allow_maintainer_to_push even when it is null' do
      merge_request.update_column(:allow_maintainer_to_push, nil)

      hash = serializer.serialize(merge_request.reload)

      expect(hash).to have_key('allow_maintainer_to_push')
      expect(hash['allow_maintainer_to_push']).to be_nil
    end

    it 'stores under <uuid>/merge_requests/<iid>.yml' do
      expect(serializer.file_path(merge_request))
        .to eq(sync_path("merge_requests/#{merge_request.iid}.yml"))
    end

    it 'names its own relation in the schema header' do
      expect(serializer.serialize(merge_request)['_schema'])
        .to start_with('merge_requests@')
    end
  end

  # The sync commits a file only when its blob oid differs from the one on the
  # branch, so identical data has to serialize to identical bytes -- otherwise
  # every pass rewrites every file and never converges. The catalogs are the
  # case most exposed to it: labels_for/milestones_for are `.or()` queries with
  # no ORDER BY, so the database is free to return rows in any order it likes.
  describe 'catalog determinism' do
    let_it_be(:group) { create(:group) }
    let_it_be(:catalog_project) { create(:project, :private, group: group) }

    before_all do
      create(:group_label, group: group, title: 'inherited')
      create(:label, project: catalog_project, title: 'bug')
      create(:label, project: catalog_project, title: 'chore')
      create(:milestone, group: group, title: 'group-wide')
      create(:milestone, project: catalog_project, title: 'backlog')
      create(:milestone, project: catalog_project, title: 'next')
    end

    %i[labels milestones].each do |key|
      it "orders #{key}.yml the same however the rows arrive" do
        records = OC::WorkItems.public_send(:"#{key}_for", catalog_project).to_a

        forwards = serializer.to_yaml_catalog(catalog_project, key, records)
        backwards = described_class.new.to_yaml_catalog(catalog_project, key, records.reverse)
        shuffled = described_class.new.to_yaml_catalog(catalog_project, key, records.shuffle)

        expect(backwards).to eq(forwards)
        expect(shuffled).to eq(forwards)
      end

      it "serializes #{key}.yml identically across serializer instances" do
        records = OC::WorkItems.public_send(:"#{key}_for", catalog_project)
        first = described_class.new.to_yaml_catalog(catalog_project, key, records)
        second = described_class.new.to_yaml_catalog(catalog_project, key, records)

        expect(second).to eq(first)
      end
    end

    # created_at alone ties whenever records are made in one go, which is
    # exactly what a seeded or imported project looks like.
    it 'stays stable when every record shares a created_at' do
      timestamp = Time.utc(2026, 1, 2, 3, 4, 5)
      ::Label.where(project_id: catalog_project.id).update_all(created_at: timestamp)
      records = OC::WorkItems.labels_for(catalog_project).to_a

      expect(described_class.new.to_yaml_catalog(catalog_project, :labels, records.reverse))
        .to eq(described_class.new.to_yaml_catalog(catalog_project, :labels, records))
    end
  end

  # A file dragged into a comment lives outside the repository, so the branch
  # carries the link and not the file. The uploads key is what says so.
  describe 'uploads' do
    let(:secret) { 'aa11bb22cc33dd44ee55ff6600112233' }
    let(:path) { "/uploads/#{secret}/diagram.png" }
    let(:url) { "#{Gitlab.config.gitlab.base_url}/#{project.full_path}#{path}" }
    let(:body) { "Here it is:\n\n![diagram](#{path})" }

    let(:issue) { create(:issue, project: project, description: body) }

    def upload!(**overrides)
      create(:upload, :issuable_upload, model: project, secret: secret,
        filename: 'diagram.png', **overrides)
    end

    it 'reports the path, and what the uploads row knows about it' do
      upload!(size: 184_320, checksum: 'a' * 64)

      expect(serializer.serialize(issue)['uploads'])
        .to eq([{ 'url' => url, 'size' => 184_320, 'checksum' => 'a' * 64 }])
    end

    # Upload#needs_checksum? requires local storage, so an instance keeping
    # uploads in object storage reports none.
    it 'leaves out a checksum that was never computed' do
      upload!(checksum: nil)

      expect(serializer.serialize(issue)['uploads'].first).not_to have_key('checksum')
    end

    it 'still reports a file whose uploads row is gone' do
      expect(serializer.serialize(issue)['uploads']).to eq([{ 'url' => url }])
    end

    # The question this key exists to answer: an image pasted into the third
    # comment is a file the document needs, wherever in the document it sits.
    it 'gathers references from nested notes, not just the description' do
      plain = create(:issue, project: project)
      create(:note, noteable: plain, project: project, note: body)
      upload!

      expect(serializer.serialize(plain.reload)['uploads'].pluck('url')).to eq([url])
    end

    it 'reports each file once however many times it is referenced' do
      create(:note, noteable: issue, project: project, note: "again: ![diagram](#{path})")
      upload!

      expect(serializer.serialize(issue.reload)['uploads'].size).to eq(1)
    end

    it 'orders them by path, so an unchanged document serializes the same' do
      other = "/uploads/#{'0' * 32}/aardvark.png"
      create(:note, noteable: issue, project: project, note: "![a](#{other})")

      expect(serializer.serialize(issue.reload)['uploads'].pluck('url'))
        .to eq(["#{Gitlab.config.gitlab.base_url}/#{project.full_path}#{other}", url])
    end

    it 'leaves the key out of a document that points at no files' do
      expect(serializer.serialize(create(:issue, project: project))).not_to have_key('uploads')
    end

    # Same reason the identity map is built from the filtered document: a file
    # named only by a comment nobody may see must not be advertised.
    it 'forgets a file named only by a note it stripped' do
      public_project = create(:project, :public)
      public_issue = create(:issue, project: public_project)
      create(:note, :confidential, noteable: public_issue, project: public_project, note: body)

      expect(serializer.serialize(public_issue.reload)).not_to have_key('uploads')
    end
  end

  # ids.yml, the index from database ids to the identifiers a reader can act
  # on. Built as a side effect of serializing rather than from a query of its
  # own, so it can only ever name something a document already named.
  describe '#identities' do
    let_it_be(:group) { create(:group) }
    let_it_be(:grouped_project) { create(:project, :private, group: group) }
    let_it_be(:group_label) { create(:group_label, group: group, title: 'inherited') }

    let_it_be(:issue) do
      create(:labeled_issue, project: grouped_project, author: user, labels: [group_label]).tap do |issue|
        create(:award_emoji, awardable: issue, name: 'thumbsup', user: user)
      end
    end

    it 'resolves the ids of every kind a document carries' do
      serializer.serialize(issue)

      expect(serializer.identities['projects']).to eq(grouped_project.id => grouped_project.full_path)
      expect(serializer.identities['groups']).to eq(group.id => group.full_path)
      expect(serializer.identities['users'][user.id])
        .to eq('username' => user.username, 'name' => user.name)
    end

    it 'publishes an email address only for a user who chose to' do
      publisher = create(:user, :public_email)
      create(:note, noteable: issue, project: grouped_project, author: publisher)

      serializer.serialize(issue.reload)

      expect(serializer.identities['users'][publisher.id]['public_email']).to eq(publisher.public_email)
      expect(serializer.identities['users'][user.id]).not_to have_key('public_email')
    end

    it 'accumulates across every document of a pass' do
      other = create(:issue, project: grouped_project, author: create(:user))

      serializer.serialize(issue)
      serializer.serialize(other)

      expect(serializer.identities['users'].keys).to include(user.id, other.author_id)
    end

    # award_emoji.user_id is one of the few id columns with no foreign key
    # behind it, so hard-deleting a user really does leave one dangling -- and
    # an id nothing resolves to has to be left out rather than mapped to null.
    it 'leaves out an id that resolves to nothing' do
      issue.award_emoji.first.update_columns(user_id: non_existing_record_id)

      serializer.serialize(issue.reload)

      expect(serializer.identities['users']).not_to have_key(non_existing_record_id)
      expect(serializer.identities['users'].values).to all(be_present)
    end

    # The walk runs on the filtered document, so anything the confidentiality
    # rules removed takes its author out of the map with it. Collecting from
    # the record instead would put the author of a stripped note back in.
    it 'does not name the author of a note it stripped' do
      public_project = create(:project, :public)
      public_issue = create(:issue, project: public_project, author: user)
      insider = create(:user)
      create(:note, :confidential, noteable: public_issue, project: public_project, author: insider)

      hash = serializer.serialize(public_issue.reload)

      expect(hash['notes']).to be_nil
      expect(serializer.identities['users']).to have_key(user.id)
      expect(serializer.identities['users']).not_to have_key(insider.id)
    end

    describe 'a merge request from a fork' do
      # Not let_it_be: fork_from writes to the row, and the mutation would
      # outlive the example.
      let(:merge_request) { create(:merge_request, source_project: project, target_project: project) }

      # Pointing source_project_id at another project by hand rather than
      # building a real fork: the gate reads the column, and a genuine fork
      # would need two repositories to say nothing more than this does.
      def fork_from(source)
        merge_request.update_columns(source_project_id: source.id)
        serializer.serialize(merge_request.reload)
      end

      it 'does not name a private source project belonging to someone else' do
        foreign = create(:project, :private)

        hash = fork_from(foreign)

        expect(hash['source_project_id']).to eq(foreign.id)
        expect(serializer.identities['projects']).not_to have_key(foreign.id)
      end

      it 'names a public source project' do
        foreign = create(:project, :public)

        fork_from(foreign)

        expect(serializer.identities['projects'][foreign.id]).to eq(foreign.full_path)
      end

      it 'names a private source project under the same root namespace' do
        sibling = create(:project, :private, namespace: project.namespace)

        fork_from(sibling)

        expect(serializer.identities['projects'][sibling.id]).to eq(sibling.full_path)
      end
    end
  end

  describe '#to_yaml_identities' do
    let(:map) do
      {
        'users' => { 9 => { 'username' => 'nine' }, 2 => { 'username' => 'two' } },
        'groups' => { 5 => 'a-group' },
        'projects' => { 7 => 'a-group/a-project' }
      }
    end

    it 'leads with a schema header naming its own relation' do
      expect(YAML.safe_load(serializer.to_yaml_identities(map)).each_key.first).to eq('_schema')
      expect(YAML.safe_load(serializer.to_yaml_identities(map))['_schema']).to eq('ids@1')
    end

    it 'orders the sections widest scope first, and each id ascending' do
      expect(serializer.to_yaml_identities(map).lines.grep(/^(?!_)\w+:|^ {2}\d+:/).map(&:strip))
        .to eq(['projects:', '7: a-group/a-project', 'groups:', '5: a-group', 'users:', '2:', '9:'])
    end

    it 'is nil when nothing was resolved, so the caller deletes the file' do
      expect(serializer.to_yaml_identities({})).to be_nil
      expect(serializer.to_yaml_identities('users' => {})).to be_nil
    end

    it 'round-trips through parse_identities' do
      parsed = described_class.parse_identities(serializer.to_yaml_identities(map))

      expect(parsed).to eq(map.transform_values { |entries| entries.sort.to_h })
    end

    it 'refuses a file that is not one of ours, so the caller rebuilds it' do
      expect(described_class.parse_identities(YAML.dump('_schema' => 'issues@1', 'users' => { 1 => 'x' })))
        .to eq({})
      expect(described_class.parse_identities('users: [unclosed')).to eq({})
      expect(described_class.parse_identities(nil)).to eq({})
    end
  end

  # The map is keyed by attribute name, which only works while every id-shaped
  # attribute the export can emit is either resolved or knowingly left alone.
  # A GitLab upgrade that adds one should fail here rather than quietly emit an
  # id nothing can resolve.
  describe 'coverage of the export schema' do
    # Returns [id attribute names, paths of relations exported as raw rows].
    def scan(options, path)
      ids = Array(options[:only]).map(&:to_s).select { |name| name.end_with?('_id') }
      raw = options[:only].blank? ? [path] : []

      Array(options[:include]).each do |entry|
        entry.each do |name, nested|
          nested_ids, nested_raw = scan(nested, "#{path}/#{name}")
          ids += nested_ids
          raw += nested_raw
        end
      end

      [ids, raw]
    end

    let(:relations) do
      described_class::RELATION_KEYS.values +
        described_class::CATALOG_KEYS +
        [described_class::COMMIT_NOTES_KEY]
    end

    let(:scanned) do
      relations.map { |key| scan(serializer.send(:relation_options, key), key.to_s) }
        .transpose.map(&:flatten)
    end

    # Which matters because a relation with no included_attributes exports its
    # whole row, so its columns -- not the schema file -- are what the check
    # below has to read. commit_notes is the only one, and the guard is here so
    # that a second one cannot appear unnoticed and slip past it.
    it 'takes commit_notes as the only relation exported as a raw row' do
      expect(scanned.last).to contain_exactly('commit_notes')
    end

    it 'resolves or explicitly ignores every id the schema can emit' do
      declared = scanned.first + ::Note.column_names.select { |name| name.end_with?('_id') }

      expect(declared.uniq - described_class::IDENTITY_KEYS.keys - described_class::UNRESOLVED_ID_KEYS -
        described_class::LOCAL_ONLY_ID_KEYS).to be_empty
    end

    it 'does not carry keys for relations it never serializes' do
      declared = scanned.first + ::Note.column_names

      expect(described_class::IDENTITY_KEYS.keys - declared).to be_empty
    end
  end

  describe 'commit notes' do
    let(:commit_id) { 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42' }

    def commit_note(body, author: user)
      create(:note_on_commit, project: project, author: author, commit_id: commit_id, note: body)
    end

    def serialize_commit_notes(notes)
      serializer.serialize_commit_notes(project, commit_id, notes)
    end

    it 'groups every note on the commit into one document' do
      notes = [commit_note('first'), commit_note('second')]

      hash = serialize_commit_notes(notes)

      expect(hash['_schema']).to start_with('commit_notes@')
      expect(hash['commit_id']).to eq(commit_id)
      expect(hash['notes'].pluck('note')).to contain_exactly('first', 'second')
      expect(hash['web_url']).to eq(Gitlab::Routing.url_helpers.project_commit_url(project, commit_id))
    end

    it 'stores under <uuid>/commit_notes/<sha>.yml' do
      expect(described_class.commit_notes_file_path(commit_id))
        .to eq(sync_path("commit_notes/#{commit_id}.yml"))
    end

    # commit_notes is the one relation with no `included_attributes` entry in
    # import_export.yml, so `to_json` hands back the primary key too.
    it 'drops the DB id the export schema would otherwise keep' do
      hash = serialize_commit_notes([commit_note('a note')])

      expect(hash['notes'].first).not_to have_key('id')
      expect(hash['notes'].first['note']).to eq('a note')
    end

    it 'keeps the author name so the note survives an import elsewhere' do
      other = create(:user, name: 'Commit Reviewer')

      hash = serialize_commit_notes([commit_note('looks wrong', author: other)])

      expect(hash['notes'].first['author']['name']).to eq('Commit Reviewer')
    end

    it 'is nil when the commit has no notes, so the caller deletes the file' do
      expect(serialize_commit_notes([])).to be_nil
      expect(serializer.to_yaml_commit_notes(project, commit_id, [])).to be_nil
    end

    it 'round-trips through YAML.safe_load' do
      notes = [commit_note('a note')]

      yaml = serializer.to_yaml_commit_notes(project, commit_id, notes)

      expect(YAML.safe_load(yaml)).to eq(serialize_commit_notes(notes))
    end

    it 'is byte-stable regardless of the order the notes arrive in' do
      notes = [commit_note('first'), commit_note('second')]

      expect(serializer.to_yaml_commit_notes(project, commit_id, notes.reverse))
        .to eq(described_class.new.to_yaml_commit_notes(project, commit_id, notes))
    end
  end

  describe 'confidentiality filtering' do
    context 'on a private project, which does not sync confidential content by default' do
      it 'drops confidential issues' do
        issue = create(:issue, :confidential, project: project)

        expect(serializer.serialize(issue)).to be_nil
      end

      # A note carries its own confidential flag, so a perfectly visible issue
      # can hold a team-only comment. The issue is still synced; only that note
      # is dropped. (Notes on a *confidential* issue need no such handling --
      # the whole file is dropped one level up.)
      # GitLab writes a cross-reference note on the *referenced* record and
      # hides it per reader (Note#system_note_visible_for?). A file on a branch
      # has no reader to filter for, so a note naming a confidential issue
      # would tell anyone who can clone the repository that it exists.
      describe 'cross-reference system notes' do
        let_it_be(:issue) { create(:issue, project: project, title: 'the referenced issue') }

        def cross_reference(body)
          note = create(:note, :system, noteable: issue, project: project, note: body)
          create(:system_note_metadata, note: note, action: 'cross_reference')
          note
        end

        # commit_notes is the one relation whose export tree carries no
        # system_note_metadata, so the action is not in the serialized hash to
        # key off -- and a commit gets these notes like any other noteable.
        it 'drops one on a commit, where the metadata is not exported' do
          commit_id = 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42'
          hidden = create(:issue, :confidential, project: project)
          create(:note_on_commit, :system, project: project, commit_id: commit_id,
            note: "mentioned in issue ##{hidden.iid}")
          kept = create(:note_on_commit, project: project, commit_id: commit_id, note: 'a real comment')

          hash = serializer.serialize_commit_notes(project, commit_id, project.commit_notes.reload)

          expect(Array(hash['notes']).pluck('note')).to contain_exactly(kept.note)
        end

        # `notes` is absent, not empty, once every note has been dropped.
        def note_bodies
          Array(serializer.serialize(issue.reload)['notes']).pluck('note')
        end

        it 'drops one that names a confidential issue' do
          hidden = create(:issue, :confidential, project: project)
          cross_reference("mentioned in issue ##{hidden.iid}")

          expect(note_bodies).to be_empty
        end

        it 'keeps one that names an ordinary issue' do
          visible = create(:issue, project: project)
          cross_reference("mentioned in issue ##{visible.iid}")

          expect(note_bodies).to contain_exactly("mentioned in issue ##{visible.iid}")
        end

        # Only issues can be confidential, and a merge request or commit in
        # this project is visible to anyone who can read its repository.
        # Several actions carry references without opening with the prefix, so
        # upstream scans them on the strength of the action alone
        # (SystemNoteMetadata::TYPES_WITH_CROSS_REFERENCES). Matching only the
        # prefix would let these through.
        %w[relate duplicate moved closed].each do |action|
          it "drops a #{action} note naming a confidential issue" do
            hidden = create(:issue, :confidential, project: project)
            note = create(:note, :system, noteable: issue, project: project,
              note: "marked this issue as related to ##{hidden.iid}")
            create(:system_note_metadata, note: note, action: action)

            expect(note_bodies).to be_empty
          end
        end

        it 'keeps such a note when the issue it names is an ordinary one' do
          visible = create(:issue, project: project)
          note = create(:note, :system, noteable: issue, project: project,
            note: "marked this issue as related to ##{visible.iid}")
          create(:system_note_metadata, note: note, action: 'relate')

          expect(note_bodies).to contain_exactly("marked this issue as related to ##{visible.iid}")
        end

        # A system note whose action carries no references and which does not
        # open with the prefix is never scanned at all.
        it 'leaves an unrelated system note alone' do
          note = create(:note, :system, noteable: issue, project: project, note: 'changed the description')
          create(:system_note_metadata, note: note, action: 'description')

          expect(note_bodies).to contain_exactly('changed the description')
        end

        it 'keeps merge request and commit references' do
          cross_reference('mentioned in merge request !3')
          cross_reference('mentioned in commit abc1234def')

          expect(note_bodies).to contain_exactly(
            'mentioned in merge request !3', 'mentioned in commit abc1234def')
        end

        describe 'references into another project' do
          # Namespace#to_reference_base emits a bare path for a sibling in the
          # same namespace, so this form has no slash to spot it by.
          it 'resolves a bare sibling path against this project namespace' do
            sibling = create(:project, :private, namespace: project.namespace, path: 'sibling')
            hidden = create(:issue, :confidential, project: sibling)
            cross_reference("mentioned in issue sibling##{hidden.iid}")

            expect(note_bodies).to be_empty
          end

          it 'keeps a private sibling under the same root namespace' do
            sibling = create(:project, :private, namespace: project.namespace, path: 'sibling')
            visible = create(:issue, project: sibling)
            cross_reference("mentioned in issue sibling##{visible.iid}")

            expect(note_bodies).to contain_exactly("mentioned in issue sibling##{visible.iid}")
          end

          # A different root namespace is a different owner: naming their
          # private project discloses that it exists.
          it 'drops a private project under a different root namespace' do
            stranger = create(:project, :private, path: 'stranger')
            visible = create(:issue, project: stranger)
            cross_reference("mentioned in issue #{stranger.full_path}##{visible.iid}")

            expect(note_bodies).to be_empty
          end

          it 'keeps a public project under a different root namespace' do
            open = create(:project, :public, path: 'open')
            visible = create(:issue, project: open)
            cross_reference("mentioned in issue #{open.full_path}##{visible.iid}")

            expect(note_bodies).to contain_exactly("mentioned in issue #{open.full_path}##{visible.iid}")
          end

          # Project.reference_pattern's namespace capture is
          # FULL_NAMESPACE_FORMAT_REGEX, so a project nested several groups
          # deep resolves without any path handling of our own.
          it 'resolves a project nested under subgroups' do
            subgroup = create(:group, parent: create(:group))
            nested = create(:project, :private, group: subgroup, path: 'nested')
            hidden = create(:issue, :confidential, project: nested)
            cross_reference("mentioned in issue #{nested.full_path}##{hidden.iid}")

            expect(nested.full_path.count('/')).to eq(2)
            expect(note_bodies).to be_empty
          end

          it 'drops a renamed or deleted project, which cannot be judged at all' do
            cross_reference('mentioned in issue gone-group/gone-project#7')

            expect(note_bodies).to be_empty
          end

          # What makes this affordable on a full sync: SyncService keeps one
          # serializer for the whole pass, so a project referenced by ten
          # thousand issues is looked up once, not ten thousand times.
          it 'resolves each referenced project once across the whole pass' do
            other = create(:project, :public, path: 'referenced')
            visible = create(:issue, project: other)
            body = "mentioned in issue #{other.full_path}##{visible.iid}"

            issues = Array.new(3) do
              create(:issue, project: project).tap do |referrer|
                note = create(:note, :system, noteable: referrer, project: project, note: body)
                create(:system_note_metadata, note: note, action: 'cross_reference')
              end
            end

            expect(Project).to receive(:find_by_full_path).once.and_call_original

            issues.each { |referrer| serializer.serialize(referrer.reload) }
          end
        end

        context 'on a public project, whose branch anyone can read' do
          let_it_be(:project) { create(:project, :public) }
          let_it_be(:issue) { create(:issue, project: project) }

          it 'drops a reference to a private project' do
            secret = create(:project, :private)
            visible = create(:issue, project: secret)
            cross_reference("mentioned in issue #{secret.full_path}##{visible.iid}")

            expect(note_bodies).to be_empty
          end

          # Public, but its issues are for members only -- naming one discloses
          # just as much as naming an issue in a private project would.
          it 'drops a reference to a public project that hides its issues' do
            restricted = create(:project, :public, :issues_private)
            visible = create(:issue, project: restricted)
            cross_reference("mentioned in issue #{restricted.full_path}##{visible.iid}")

            expect(note_bodies).to be_empty
          end

          it 'keeps a reference to a fully public project' do
            open = create(:project, :public)
            visible = create(:issue, project: open)
            cross_reference("mentioned in issue #{open.full_path}##{visible.iid}")

            expect(note_bodies).to contain_exactly("mentioned in issue #{open.full_path}##{visible.iid}")
          end
        end

        it 'leaves ordinary comments that merely look like references alone' do
          create(:note, noteable: issue, project: project, note: 'see #1 and other/project#2')

          expect(note_bodies).to contain_exactly('see #1 and other/project#2')
        end

        it 'keeps them all when the project opted into confidential content' do
          including_project = create(:project, :private)
          including_project.include_work_items_sync_confidential!(true)
          included_issue = create(:issue, project: including_project)
          hidden = create(:issue, :confidential, project: including_project)
          note = create(:note, :system, noteable: included_issue, project: including_project,
            note: "mentioned in issue ##{hidden.iid}")
          create(:system_note_metadata, note: note, action: 'cross_reference')

          expect(serializer.serialize(included_issue.reload)['notes'].pluck('note'))
            .to contain_exactly("mentioned in issue ##{hidden.iid}")
        end
      end

      it 'strips internal notes but keeps the visible issue they are on' do
        issue = create(:issue, project: project, title: 'a visible issue')
        create(:note, noteable: issue, project: project, note: 'ordinary note')
        create(:note, noteable: issue, project: project, confidential: true, note: 'internal note')

        hash = serializer.serialize(issue.reload)

        expect(hash['title']).to eq('a visible issue')
        expect(hash['confidential']).to be(false)
        expect(hash['notes'].pluck('note')).to contain_exactly('ordinary note')
      end
    end

    context 'on a private project that opted into confidential content' do
      let_it_be_with_reload(:including_project) { create(:project, :private) }

      before do
        including_project.include_work_items_sync_confidential!(true)
      end

      it 'serializes confidential issues and internal notes' do
        issue = create(:issue, :confidential, project: including_project)
        create(:note, noteable: issue, project: including_project, confidential: true, note: 'internal note')

        hash = serializer.serialize(issue.reload)

        expect(hash['confidential']).to be(true)
        expect(hash['notes'].pluck('note')).to include('internal note')
      end
    end

    context 'on a public project' do
      let_it_be(:public_project) { create(:project, :public) }

      it 'drops confidential issues entirely' do
        confidential_issue = create(:issue, :confidential, project: public_project)

        expect(serializer.serialize(confidential_issue)).to be_nil
        expect(serializer.to_yaml(confidential_issue)).to be_nil
      end

      it 'strips internal notes from public issues' do
        issue = create(:issue, project: public_project)
        create(:note, noteable: issue, project: public_project, note: 'public note')
        create(:note, noteable: issue, project: public_project, confidential: true, note: 'internal note')

        notes = serializer.serialize(issue)['notes'].pluck('note')

        expect(notes).to include('public note')
        expect(notes).not_to include('internal note')
      end
    end
  end
end
