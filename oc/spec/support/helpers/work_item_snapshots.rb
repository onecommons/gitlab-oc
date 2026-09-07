# frozen_string_literal: true

# Shared setup for the work item snapshots in oc/spec/fixtures/work_items/.
# Used by oc/spec/services/oc/work_items/record_serializer_snapshot_spec.rb in
# both of its modes: verifying the committed snapshots, and regenerating them.
#
# Keeping the setup here means the generator and the assertion cannot drift --
# they are the same code path.
#
# "Snapshot" here follows GitLab's own usage in spec/requests/api/
# markdown_snapshot_spec.rb: committed expected output, compared byte for byte
# and regenerated deliberately. It does not mean Jest snapshot testing.
module WorkItemSnapshots
  SNAPSHOT_DIR = 'oc/spec/fixtures/work_items'

  # Every timestamp in the snapshots is frozen to this. Examples wrap their
  # setup in travel_to(SNAPSHOT_TIME); the helper deliberately does not, so the
  # generator and the verifier freeze time identically.
  SNAPSHOT_TIME = Time.utc(2026, 1, 2, 3, 4, 5)

  # Notes are pinned apart from the frozen "now" so the serializer's
  # deterministic sort ([created_at, iid, dumped entry]) has a stable key.
  #
  # The merge request's threaded pair is deliberately interleaved with its
  # standalone notes (00, 01, 02, 03): a thread is held together by
  # discussion_id, not by adjacency, and the snapshot should say so.
  AUTHOR_NOTE_TIME = Time.utc(2026, 1, 2, 3, 0, 0)
  THREAD_NOTE_TIME = Time.utc(2026, 1, 2, 3, 1, 0)
  COMMENTER_NOTE_TIME = Time.utc(2026, 1, 2, 3, 2, 0)
  THREAD_REPLY_TIME = Time.utc(2026, 1, 2, 3, 3, 0)

  # The merge request is the one record with two events in a single array, so
  # it is the one place they have to be pinned apart for the same reason the
  # notes are. Events carry no iid, so two written at the frozen "now" tie all
  # the way down to the dumped-entry tiebreak, whose first difference is the
  # author id -- and comparing ids as text only matches comparing them as
  # numbers while both have the same digit count. An author with id 999 beside
  # a commenter with id 1000 would order the pair the other way round and fail
  # the committed snapshot.
  OPEN_EVENT_TIME = Time.utc(2026, 1, 2, 2, 58, 0)
  APPROVE_EVENT_TIME = Time.utc(2026, 1, 2, 2, 59, 0)

  # Dates, unlike the timestamps above, are columns the caller sets -- travel_to
  # does not reach them.
  MILESTONE_START_DATE = Date.new(2026, 1, 1)
  MILESTONE_DUE_DATE = Date.new(2026, 2, 1)

  # A synthetic sha. Note only validates that commit_id is present for a commit
  # note, never that the commit exists, so the snapshot project needs no
  # repository -- and the sha stays a literal in the committed fixture, which is
  # what names the file.
  SNAPSHOT_COMMIT_SHA = 'f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42'

  # Discussion ids are pinned rather than substituted. A derived one is a
  # random 40-hex string, and Psych quotes a scalar that could be misread as a
  # number -- so '05...' is emitted as '0595...' while 'f0...' is emitted bare.
  # A format() placeholder cannot reproduce that: the committed snapshot bakes
  # in one choice and the next run makes the other, about one time in eight.
  # Pinning them to literals starting with a letter removes both the quoting
  # hazard and three placeholders.
  #
  # ensure_discussion_id is a no-op once the attribute is set, so passing one
  # to the factory sticks. A reply is left alone: in_reply_to copies its
  # parent's, which is the thing the snapshot is there to show.
  AUTHOR_DISCUSSION_ID = 'aa11000000000000000000000000000000000000'
  COMMENTER_DISCUSSION_ID = 'bb22000000000000000000000000000000000000'
  THREAD_DISCUSSION_ID = 'cc33000000000000000000000000000000000000'
  COMMIT_AUTHOR_DISCUSSION_ID = 'dd44000000000000000000000000000000000000'
  COMMIT_COMMENTER_DISCUSSION_ID = 'ee55000000000000000000000000000000000000'

  # Deliberately awkward markdown: headings, a table, a fenced code block, a
  # blockquote, an HTML comment, quotes, a trailing backslash, and literal
  # percent signs -- which the snapshots escape as %% so format() leaves them
  # alone. Non-interpolating heredocs keep \t and #{} literal.
  SNAPSHOT_DESCRIPTION = <<~'MD'
    ## Summary

    The deploy step fails **100% of the time** when `unfurl_type` is set to
    `blueprint` _and_ the project is public. Quick actions are documented at
    <https://docs.gitlab.com/user/project/quick_actions/>.

    ### Steps to reproduce

    1. Create a blueprint project
    2. Run the deploy with a literal percent in a variable:

       ```bash
       unfurl deploy --dryrun --var 'env=prod%' 2>&1 | tee out.log
       ```

    3. Observe `ENOENT` in `out.log`

    - [x] Reproduced locally
    - [ ] Reproduced on staging
    - [ ] Root caused

    | Environment | Result | Notes                    |
    |-------------|--------|--------------------------|
    | local       | fails  | `ENOENT`                 |
    | staging     | passes | needs a 2nd confirmation |

    > **Note:** this blocks the 15.11 rollout.
    > Tracking in ~"needs investigation".

    <!-- internal: linked to the work-items sync spike -->

    Edge cases the serializer must survive: a trailing backslash \
    a tab escape `\t`, "double" and 'single' quotes, a colon: in prose,
    and a line that looks like YAML --- but is not.
  MD

  # Quick actions are stored verbatim: the sync serializes the row as it sits
  # in the database, and QuickActions::InterpretService has already run (and
  # stripped commands) long before anything reaches the serializer. Records
  # built by factories, as below, skip that service and keep them as written.
  SNAPSHOT_AUTHOR_NOTE = <<~'MD'
    Still reproducing after the latest deploy. Setting this up per the
    [quick actions reference](https://docs.gitlab.com/user/project/quick_actions/):

    /label ~bug
    /assign @snapshot-commenter
    /estimate 2h
    /due 2026-02-01
  MD

  # A file dragged into a comment. The secret is a literal rather than a
  # generated one so the committed snapshot stays stable, and an uploads row is
  # created to match it -- otherwise the entry would be path-only and the
  # snapshot would not show what a resolved one looks like.
  #
  # It sits in a comment rather than in the description on purpose: the uploads
  # key is one list for the whole document, so the snapshot should show a file
  # reaching it from a nested record.
  #
  # The comment carries the project-relative path a user typed; the uploads
  # entry carries the URL that path resolves to, which is why the snapshot
  # shows the two in different forms.
  SNAPSHOT_UPLOAD_SECRET = 'aa11bb22cc33dd44ee55ff6600112233'
  SNAPSHOT_UPLOAD_FILE = 'deploy-failure.png'
  SNAPSHOT_UPLOAD_SIZE = 184_320
  SNAPSHOT_UPLOAD_CHECKSUM = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'

  SNAPSHOT_COMMENTER_NOTE = <<~MD
    Confirmed on staging. See `out.log` line 42 -- same `ENOENT`.

    ![deploy failure](/uploads/#{SNAPSHOT_UPLOAD_SECRET}/#{SNAPSHOT_UPLOAD_FILE})
  MD
                             .freeze

  # A two-note thread on the merge request. The root carries a literal percent
  # sign so the merge request snapshot exercises the same %%-escaping the issue
  # description does.
  SNAPSHOT_THREAD_NOTE = 'Does this cover the literal `%` case from the issue description?'
  SNAPSHOT_THREAD_REPLY = 'Yes -- covered by the round-trip spec. Reply in the same thread as the question.'

  SNAPSHOT_COMMIT_NOTE = 'This is the commit that introduced the `ENOENT`.'
  SNAPSHOT_COMMIT_REPLY = 'Agreed -- reverting it locally makes the deploy pass.'

  # Returns [issue, substitutions] where substitutions are the format() keys
  # the committed snapshot interpolates.
  def build_snapshot_issue
    author, commenter, project, label, group_label = snapshot_actors

    # One label the project owns and one it inherits: a group label is how a
    # group_id reaches a work item document at all, and so how a group comes to
    # be in ids.yml.
    issue = create(:labeled_issue,
      project: project, author: author, labels: [label, group_label],
      title: 'Snapshot issue', description: SNAPSHOT_DESCRIPTION)

    author_note = snapshot_note(issue, project, author, SNAPSHOT_AUTHOR_NOTE, AUTHOR_NOTE_TIME,
      discussion_id: AUTHOR_DISCUSSION_ID)
    commenter_note = snapshot_note(issue, project, commenter, SNAPSHOT_COMMENTER_NOTE, COMMENTER_NOTE_TIME,
      discussion_id: COMMENTER_DISCUSSION_ID)
    create(:award_emoji, awardable: issue, name: 'thumbsup', user: commenter)
    create(:upload, :issuable_upload, model: project,
      secret: SNAPSHOT_UPLOAD_SECRET, filename: SNAPSHOT_UPLOAD_FILE,
      size: SNAPSHOT_UPLOAD_SIZE, checksum: SNAPSHOT_UPLOAD_CHECKSUM)

    event_service.open_issue(issue, author)
    event_service.leave_note(author_note, author)
    event_service.leave_note(commenter_note, commenter)

    # The comment holds the project-relative path a user typed; the uploads
    # entry holds the URL it resolves to, so the two appear in different forms.
    upload_url = "#{Gitlab.config.gitlab.base_url}/#{project.full_path}" \
      "/uploads/#{SNAPSHOT_UPLOAD_SECRET}/#{SNAPSHOT_UPLOAD_FILE}"

    [issue.reload, snapshot_substitutions(issue, project, author, commenter, upload_url: upload_url)]
  end

  def build_snapshot_merge_request
    author, commenter, project, label = snapshot_actors(repository: true)
    milestone = snapshot_milestone(project, author)

    merge_request = create(:labeled_merge_request,
      source_project: project, target_project: project, author: author, labels: [label],
      milestone: milestone,
      title: 'Snapshot merge request', description: 'Fixes the snapshot issue')

    # Assigning a milestone through a factory writes the column but not the
    # history row a real Issuable::UpdateService would; create it explicitly so
    # resource_milestone_events documents its shape too.
    create(:resource_milestone_event,
      merge_request: merge_request, issue: nil, milestone: milestone, user: author,
      action: :add, state: :opened, created_at: SNAPSHOT_TIME)

    author_note = snapshot_note(merge_request, project, author, 'Ready for review.', AUTHOR_NOTE_TIME,
      factory: :note_on_merge_request, discussion_id: AUTHOR_DISCUSSION_ID)
    commenter_note = snapshot_note(merge_request, project, commenter, 'Looks good to me.', COMMENTER_NOTE_TIME,
      factory: :note_on_merge_request, discussion_id: COMMENTER_DISCUSSION_ID)
    snapshot_thread(merge_request, project, author, commenter)
    create(:award_emoji, awardable: merge_request, name: 'thumbsup', user: commenter)

    # `approved` is the one event action a merge request has that an issue does
    # not, and the approval row beside it is what the event refers to.
    create(:approval, merge_request: merge_request, user: commenter)

    pin_event(OPEN_EVENT_TIME) { event_service.open_mr(merge_request, author) }
    pin_event(APPROVE_EVENT_TIME) { event_service.approve_mr(merge_request, commenter) }
    event_service.leave_note(author_note, author)
    event_service.leave_note(commenter_note, commenter)

    # Merge request metrics rows are created by a database trigger using the
    # database clock, which travel_to cannot freeze -- pin them explicitly or
    # the snapshot regenerates differently on every run.
    merge_request.reload.metrics.update_columns(created_at: SNAPSHOT_TIME, updated_at: SNAPSHOT_TIME)

    [merge_request.reload, snapshot_substitutions(merge_request, project, author, commenter)]
  end

  # Returns [project, commit_id, notes, substitutions]. Commit notes are the
  # one relation whose file is not one record: it holds every note on a single
  # commit, keyed by sha rather than by iid.
  def build_snapshot_commit_notes
    author, commenter, project = snapshot_actors

    author_note = snapshot_commit_note(project, author, SNAPSHOT_COMMIT_NOTE, AUTHOR_NOTE_TIME,
      COMMIT_AUTHOR_DISCUSSION_ID)
    commenter_note = snapshot_commit_note(project, commenter, SNAPSHOT_COMMIT_REPLY, COMMENTER_NOTE_TIME,
      COMMIT_COMMENTER_DISCUSSION_ID)

    event_service.leave_note(author_note, author)
    event_service.leave_note(commenter_note, commenter)

    substitutions = snapshot_substitutions(nil, project, author, commenter,
      web_url: Gitlab::Routing.url_helpers.project_commit_url(project, SNAPSHOT_COMMIT_SHA))

    [project, SNAPSHOT_COMMIT_SHA, [author_note, commenter_note], substitutions]
  end

  # What each placeholder stands for, written into the snapshot as an inline
  # comment so the committed file reads as documentation of the format and not
  # just as a test expectation. Fixed rather than taken from the generating
  # run: real ids vary, and the snapshot would churn on every regeneration.
  #
  # Kept in step with the abridged example in
  # oc/doc/user/project/work_items_sync.md.
  SUBSTITUTION_EXAMPLES = {
    project_id: 42,
    group_id: 8,
    author_id: 12,
    commenter_id: 34,
    upload_url: 'https://unfurl.cloud/my-group/my-project/uploads/' \
      'aa11bb22cc33dd44ee55ff6600112233/deploy-failure.png'
  }.freeze

  EXAMPLE_PROJECT_URL = 'https://unfurl.cloud/my-group/my-project'

  # web_url keeps the route of the real value, with the host and project path
  # swapped for the example ones: each snapshot then shows the route its own
  # record gets rather than one shared example.
  def example_for(name, value)
    return SUBSTITUTION_EXAMPLES.fetch(name) unless name == :web_url

    value.to_s.sub(%r{\A.*?//[^/]+/.+?(?=/-/)}, EXAMPLE_PROJECT_URL)
  end

  EXAMPLE_COMMENT = /^([^\n]*%\{\w+\}[^\n]*?)[ \t]+# e\.g\. [^\n]*$/

  # Snapshots are interpolated with format(), which would choke on the
  # documentation comments -- and the serializer never emits them -- so they
  # come off before the comparison. Only a line that carries a placeholder is
  # touched, so a `#` inside a value (a markdown heading, a label colour) is
  # left alone. The comment trails the whole line rather than the placeholder
  # itself, because in ids.yml the placeholder is the key and anything between
  # it and the comment is the value it maps to.
  def strip_example_comments(yaml)
    yaml.gsub(EXAMPLE_COMMENT) { ::Regexp.last_match(1) }
  end

  # Which placeholders can appear as keys under each ids.yml section. Scoped
  # by section rather than matched by value like everything else: `12:` under
  # `groups:` and `12:` under `users:` name different records and really can
  # share a number, since groups and users draw ids from different sequences.
  IDENTITY_SECTIONS = {
    'projects' => %i[project_id],
    'groups' => %i[group_id],
    'users' => %i[author_id commenter_id]
  }.freeze

  # ids.yml and the reference files are where ids sit in key position, which
  # the generic value-position substitution below cannot reach.
  #
  # The heading match allows indentation because the two files nest
  # differently: ids.yml puts `users:` at the root, a reference file puts it
  # under `ids:`. Headings that name no placeholder -- `ids:` itself, or an
  # `author:` inside a note -- simply select an empty list.
  def placeholderize_identity_keys(yaml, substitutions)
    section = nil

    yaml.lines.map do |line|
      # Letters only, not \w: an id in key position (`12:` under `users:`) is
      # itself a line ending in a colon, and would otherwise be read as the
      # start of a new section -- taking the real one out of scope and leaving
      # every id below it unsubstituted.
      heading = line.match(/^\s*([a-z_]+):$/)
      section = heading[1] if heading

      IDENTITY_SECTIONS.fetch(section, []).each do |name|
        value = substitutions[name]
        next unless value

        example = example_for(name, value)
        line = line.sub(/^(\s+)#{Regexp.escape(value.to_s)}:(.*)$/, "\\1%{#{name}}:\\2  # e.g. #{example}")
      end

      line
    end.join
  end

  # Returns [project, substitutions] for the labels.yml / milestones.yml
  # catalogs.
  #
  # The project sits two levels down a group chain, and the group-owned label
  # and milestone belong to the *grandparent* -- the catalogs reach every
  # ancestor, not just the immediate parent, and a fixture built on a single
  # group could not tell the difference. Each catalog therefore holds one
  # record the project owns and one it inherits, which is what makes `group_id`
  # and a label's `type` worth reading.
  def build_snapshot_catalogs
    grandparent = create(:group, path: 'snapshot-group')
    parent = create(:group, parent: grandparent, path: 'snapshot-subgroup')
    project = create(:project, :private, group: parent, path: 'snapshot-project')

    create(:group_label, group: grandparent, title: 'inherited', color: '#0000ff',
      description: 'Owned by an ancestor group, usable from every project under it')
    project_label = create(:label, project: project, title: 'bug', color: '#ff0000',
      description: 'It is broken')
    # Priorities are per project, so an inherited label carries only this
    # project's -- see RecordSerializer#catalog_entry.
    create(:label_priority, project: project, label: project_label, priority: 1)

    author = create(:user, name: 'Snapshot Author', username: 'snapshot-author')

    create(:milestone, group: grandparent, title: '15.11',
      description: 'Work items sync rollout',
      start_date: MILESTONE_START_DATE, due_date: MILESTONE_DUE_DATE)
    project_milestone = create(:milestone, project: project, title: 'backlog',
      description: 'Not scheduled yet')

    # A milestone can carry events like any other target. Only the project's
    # gets one: a group milestone's event is written against the group, and
    # the export schema for events has no group_id -- so it would serialize
    # with neither, which documents a hole rather than the shape.
    event_service.open_milestone(project_milestone, author)

    [project, { project_id: project.id, group_id: grandparent.id, author_id: author.id }]
  end

  # Replaces the environment-specific values in serializer output with the
  # format() placeholders the committed snapshots use. Literal percent signs
  # are escaped first so format() passes them through untouched.
  def placeholderize(yaml, substitutions)
    result = yaml.gsub('%', '%%')

    # Substitute only in YAML value position -- after ": ", through end of
    # line. Matching bare occurrences corrupts the document: sequential ids
    # eventually collide with numbers in the content, and an id of 2026 turns
    # every '2026-01-02T03:04:05.000Z' timestamp into '%{author_id}-01-02...'.
    #
    # Longest values first: a URL contains the project path and iid.
    substitutions.sort_by { |_name, value| -value.to_s.length }.each do |name, value|
      example = example_for(name, value)
      result = result.gsub(/(?<=: )#{Regexp.escape(value.to_s)}$/, "%{#{name}}  # e.g. #{example}")
    end

    placeholderize_identity_keys(result, substitutions)
  end

  # Not `fixture_path`: RSpec::Rails defines that on the example group and it
  # would win over this module.
  def snapshot_path(basename)
    Rails.root.join(SNAPSHOT_DIR, basename)
  end

  private

  # Every record on the branch can carry an `events` array, and factories
  # produce none -- so without this the snapshots would document the format as
  # though the key did not exist.
  #
  # An event is nested under the record it targets, which makes the set that
  # can reach a file a short closed list: `created`, `closed` and `reopened` on
  # an issue, a merge request or a milestone; `merged` and `approved` on a
  # merge request alone; `commented` on any note. Six actions across four
  # target types.
  #
  # The snapshots show `created`, `commented` and `approved`. `closed`,
  # `reopened` and `merged` would need the record to be closed or merged, which
  # is a different snapshot rather than a richer one. A milestone's `destroyed`
  # cannot be shown at all -- Milestone deletes its events with itself, so the
  # event never outlives the record it would document.
  #
  # A `pushed` event never appears: EventCreateService writes it against the
  # project with no target at all, and the export nests events by target.
  def event_service
    EventCreateService.new
  end

  # Events carry no iid, so two of them written at the frozen "now" tie in the
  # deterministic sort. Anywhere an array holds more than one, pin them apart.
  def pin_event(time)
    yield.tap { |event| event.update_columns(created_at: time, updated_at: time) }
  end

  # The project sits in a group with a pinned path so that ids.yml resolves it
  # to a fixed full path -- a factory's default namespace is a sequence, and
  # the snapshot would churn on every run.
  #
  # Only the author publishes an email address. ids.yml carries public_email
  # when there is one and leaves the key out otherwise, and the snapshot should
  # show both shapes.
  #
  # repository: only the merge request snapshot needs one, to have a real
  # merge_request_diff. The commits it points at come from the gitlab-test
  # fixture repository, whose shas are fixed, so the snapshot stays stable.
  def snapshot_actors(repository: false)
    author = create(:user, :public_email,
      name: 'Snapshot Author', username: 'snapshot-author', email: 'snapshot-author@example.com')
    commenter = create(:user, name: 'Snapshot Commenter', username: 'snapshot-commenter')
    group = create(:group, path: 'snapshot-group')
    traits = repository ? [:private, :repository] : [:private]
    project = create(:project, *traits, group: group, path: 'snapshot-project')
    label = create(:label, project: project, title: 'bug', color: '#ff0000', description: 'It is broken')
    group_label = create(:group_label, group: group, title: 'inherited', color: '#0000ff',
      description: 'Owned by an ancestor group, usable from every project under it')

    [author, commenter, project, label, group_label]
  end

  # An imported replica, which the branch records as a pointer rather than a
  # copy. The source ids are deliberately far away from anything the local
  # sequences produce, so the two sides of the id map cannot be confused for
  # each other when reading the fixture.
  SNAPSHOT_SOURCE_INSTANCE = '9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43'
  SNAPSHOT_SOURCE_IID = 42
  SNAPSHOT_SOURCE_PATH = "#{SNAPSHOT_SOURCE_INSTANCE}/issues/#{SNAPSHOT_SOURCE_IID}.yml".freeze
  SNAPSHOT_SOURCE_WEB_URL =
    "https://other.unfurl.cloud/snapshot-group/snapshot-project/-/issues/#{SNAPSHOT_SOURCE_IID}".freeze
  SNAPSHOT_SOURCE_PROJECT_ID = 9001
  SNAPSHOT_SOURCE_AUTHOR_ID = 9002

  def build_snapshot_reference
    author, commenter, project, = snapshot_actors

    issue = create(:issue, project: project, author: author,
      title: 'Snapshot replica', description: 'Held by another instance.')

    create(:oc_replicated_work_item,
      project: project, issue: issue,
      source_instance_uuid: SNAPSHOT_SOURCE_INSTANCE,
      source_path: SNAPSHOT_SOURCE_PATH,
      source_web_url: SNAPSHOT_SOURCE_WEB_URL,
      source_iid: SNAPSHOT_SOURCE_IID,
      identities: {
        'projects' => { project.id => SNAPSHOT_SOURCE_PROJECT_ID },
        'users' => { author.id => SNAPSHOT_SOURCE_AUTHOR_ID }
      })

    [issue.reload, snapshot_substitutions(issue, project, author, commenter)]
  end

  def snapshot_milestone(project, author)
    create(:milestone, project: project, title: '15.11',
      description: 'Work items sync rollout',
      start_date: MILESTONE_START_DATE, due_date: MILESTONE_DUE_DATE).tap do |milestone|
        # A milestone is the fourth thing an event can target, and it reaches a
        # merge request document embedded rather than on its own.
        event_service.open_milestone(milestone, author)
      end
  end

  # A question and its reply. `in_reply_to:` is what copies the root's
  # discussion_id onto the reply -- the only thing tying a thread together once
  # the rows are serialized, since the export schema drops note ids. Returns the
  # root, whose discussion_id both notes share.
  def snapshot_thread(merge_request, project, author, commenter)
    root = snapshot_note(merge_request, project, commenter, SNAPSHOT_THREAD_NOTE, THREAD_NOTE_TIME,
      factory: :discussion_note_on_merge_request, discussion_id: THREAD_DISCUSSION_ID)

    create(:discussion_note_on_merge_request,
      noteable: merge_request, project: project, author: author, in_reply_to: root,
      note: SNAPSHOT_THREAD_REPLY, created_at: THREAD_REPLY_TIME, updated_at: THREAD_REPLY_TIME)

    root
  end

  def snapshot_note(noteable, project, author, body, time, factory: :note, discussion_id: nil)
    create(factory, noteable: noteable, project: project, author: author, note: body,
      discussion_id: discussion_id, created_at: time, updated_at: time)
  end

  # The :on_commit trait would otherwise attach a :repository project and the
  # sha of a real commit in it; both are overridden here.
  def snapshot_commit_note(project, author, body, time, discussion_id)
    create(:note_on_commit,
      project: project, author: author, note: body, commit_id: SNAPSHOT_COMMIT_SHA,
      discussion_id: discussion_id, created_at: time, updated_at: time)
  end

  # `record` is nil for commit notes, whose file describes a commit rather than
  # a record; those callers pass :web_url in `extra` instead.
  def snapshot_substitutions(record, project, author, commenter, extra = {})
    base = { project_id: project.id, author_id: author.id, commenter_id: commenter.id }
    base[:group_id] = project.group.id if project.group
    base[:web_url] = Gitlab::UrlBuilder.build(record) if record

    base.merge(extra)
  end
end
