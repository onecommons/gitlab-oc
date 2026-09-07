# Work items sync

Work items sync keeps a copy of your project's issues, merge requests, and
commit comments in the project's own Git repository, as plain YAML files on a
branch called `gitlab-work-items`.

Every time you open an issue, edit a description, leave a comment, or react with
an emoji, Unfurl Cloud commits the updated file to that branch a few seconds
later. Nothing changes about how you use issues and merge requests — the branch
is a mirror that keeps itself up to date in the background.

## Why you might want this

- **Your work items travel with your code.** Clone the repository and you have
  the full issue history offline, in a format you can read, grep, and diff.
- **It is a real backup.** The discussion around your code survives outside the
  database, in the same place as the code itself — the text of it, at least;
  files attached to comments are
  [linked rather than copied](#attached-files-are-linked-not-copied).
- **It is portable.** The files use the same schema as Unfurl Cloud's project
  export, so they can be imported into another instance.

## Turn it on or off

Blueprint and dashboard projects have work items sync on by default. Every
other project starts with it off.

Either way the setting is at **Settings → Repository → Work items sync**, and
you need the Maintainer role to change it. A blueprint or dashboard project can
turn sync off there, and a regular project can turn it on.

Turning it on commits everything that exists already, so the first sync on a
busy project produces one large commit. Turning it off stops new commits but
leaves the branch in place.

## What the branch looks like

The branch has no code on it — only work item files, all of them under a
directory named for the instance that wrote them, and one file at the root that
nobody generates:

```plaintext
sync.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/issues/1.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/issues/2.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/merge_requests/1.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/commit_notes/f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/labels.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/milestones.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/ids.yml
```

That first segment is this installation's unique ID, and everything below is
described relative to it. It exists so the branch can hold more than one
instance's work items: if you fetch this branch into a project on another
Unfurl Cloud installation and push its own sync on top, the two sets of files
sit side by side instead of colliding at `issues/1.yml`. Each installation only
ever writes to, and cleans up, its own directory.

`sync.yml` is the exception, and the only file here meant to be edited by hand.
It sits outside every instance directory because it describes an arrangement
between installations rather than the contents of any one of them: it says
which of the directories on this branch each installation copies from. No
installation writes it, and none deletes it. See
[Bringing in another installation's items](#bringing-in-another-installations-items).

The number in an `issues/` or `merge_requests/` filename is the issue or merge
request number as it appears in the interface, so `issues/42.yml` is issue
`#42`. Comments left on a commit are grouped by that commit's SHA, so
`commit_notes/<sha>.yml` holds every comment on that one commit.

`labels.yml` and `milestones.yml` are catalogs: the project's whole vocabulary,
including everything it inherits from the groups above it. Each work item file
already carries a full copy of the labels and milestone it uses, so these two
are for what the work items do not mention — a label nobody has applied yet, a
milestone with nothing in it, or the description and dates of one whose issues
are all closed. They are rewritten by the nightly job rather than the moment
you rename something.

## Items this project only holds a copy of

An issue or merge request imported from another Unfurl Cloud installation is a
read-only copy, and its file says so rather than repeating the contents:

```yaml
_schema: issue_reference@1
source_path: 9f3c1e77-.../issues/42.yml
source_web_url: https://other.unfurl.cloud/group/project/-/issues/42
web_url: https://unfurl.cloud/my-group/my-project/-/work_items/7
ids:
  projects:
    77: 42
  users:
    500: 12
```

It sits at the path a normal file would, so anyone reading the branch can tell
the item exists here — and where the original lives — without this project
appearing to be the source of something it only mirrors. Without that, fetching
a branch between installations would multiply the same issue into a copy per
installation, each looking equally original.

The `_schema` is how you tell the two apart: `issues@1` holds an issue,
`issue_reference@1` points at one.

The `ids` block reads *local ID: source ID*, and it is the one thing in the
file you could not work out for yourself. Both installations publish an
`ids.yml`, and between them they explain every ID either one uses — but neither
says that *their* user 12 and *our* user 500 are the same person. That was a
decision this installation made while importing, by matching a verified public
email or a username, and this is where it is written down.

The block is absent when nothing was matched — everyone in the item was someone
this installation could not place, so every one of them is the Ghost User and
there is no correspondence to record. See
[Trusting identities](#trusting-identities) for what it takes to match someone.

## What a file holds

Each file holds the whole item, including its comments. Abridged, a real file
has more fields:

```yaml
_schema: issues@1
title: Deploy fails on public blueprints
author_id: 12
created_at: '2026-01-02T03:04:05.000Z'
state: opened
description: |
  ## Summary

  The deploy step fails when the project is public.
notes:
- note: Confirmed on staging.
  author_id: 34
  created_at: '2026-01-02T03:02:00.000Z'
  author:
    name: Alex Chen
label_links:
- label:
    title: bug
    color: "#ff0000"
web_url: https://unfurl.cloud/my-group/my-project/-/work_items/1
```

Fields with nothing in them are left out rather than written as empty. A file
holds what the item actually says, not the full list of everything an item
could have — so a missing key means "not set", and roughly halves the length of
a typical merge request file.

Every file starts with a `_schema` line so a program reading the branch can
tell what it is holding without guessing from the path. It reads
`<record>@<layout>`:

- **`issues`** — which kind of record the file holds: `issues`,
  `merge_requests`, or `commit_notes`. This is also the directory name and the
  name of the relation in Unfurl Cloud's project export.
- **`@1`** — the layout of the file itself. It changes only when we change how
  a file is put together, and a reader that does not recognise the number
  should stop rather than guess.

The version of the *export* schema — which tells you whether the fields inside
are the ones you expect — is recorded on the commit rather than in the file:

```shell
git log -1 --format='%(trailers:key=Work-Items-Export-Schema)' -- issues/42.yml
```

That is deliberate. A file is written by exactly one commit, so the commit
knows precisely which export schema produced it, and can never disagree with
the file the way a header written at some earlier rewrite could. It also means
an Unfurl Cloud upgrade that changes the export format for something this
branch does not even carry leaves your files alone, instead of rewriting every
one of them to update a line at the top.

## Looking up who and what an ID refers to

The files are full of numbers — `author_id: 12`, `project_id: 42`. Those are
database IDs, which mean nothing outside the Unfurl Cloud instance that wrote
them. `ids.yml` is the index that turns them into something you can use:

```yaml
_schema: ids@1
projects:
  42: my-group/my-project
groups:
  8: my-group
users:
  12:
    username: alice
    name: Alice Nakamura
    public_email: alice@example.com
  34:
    username: alex
    name: Alex Chen
```

`name` is the display name you see beside a comment in the interface. The
files themselves carry it only for the author of an item or a comment, so for
everyone else — whoever last edited something, who is assigned, who left a
thumbs-up — this file is where the name comes from. `public_email` appears
only for users who chose to publish one on their profile.

Two things worth knowing about it:

- **It is a snapshot, not a permanent key.** Usernames and paths can be
  changed by their owners, and a project can be renamed or moved. The file
  says what these IDs were called when it was written. Read the `ids.yml` of
  the same commit as the file you are reading — `git show <sha>:<instance>/ids.yml`
  — and the two agree.
- **It is kept out of the item files on purpose.** Putting the map at the top
  of every file would mean one person changing their username rewrote every
  file they had ever commented on. Here a rename changes one file.

A project a reader of this repository could not otherwise see — the source
project of a merge request from a private fork, say — is left out of the map
rather than named. The ID stays in the file; there is just nothing here that
turns it into a path.

## What is included

Everything needed to reconstruct the item: title, description, state, author,
timestamps, comments (including system notes such as "changed the description"),
labels, milestone, assignees, time tracking, award emoji, and the label,
milestone, and state change history. The one exception is files attached to a
comment, which are [linked rather than copied](#attached-files-are-linked-not-copied).

Merge request files also include reviewers, approvals, and the source and target
branches — but not the code changes themselves, since the code already lives in
the same repository. What they carry instead is the diff's coordinates:

```yaml
merge_request_diff:
  created_at: '2026-01-02T03:04:05.000Z'
  base_commit_sha: ae73cb07c9eeaf35924a10f713b364d32b2dd34f
  start_commit_sha: 0b4bc9a49b562e85de7cc9e834518ea6828729b9
  head_commit_sha: b83d6e391c22777fca1ed3012fce84f633d7fed0
  real_size: '20'
  commits_count: 29
  files_count: 20
  sorted: true
  diff_type: regular
```

Those three SHAs are the corners of the diff GitLab displayed, so
`git diff <base_commit_sha>..<head_commit_sha>` in this repository reproduces
it exactly rather than approximating it against the current target branch. The
per-file patch text and the per-commit list are left out: they are twenty times
the size of everything else in the file, and they describe code you already
have. Only the current version is recorded — a merge request's older diff
versions, the ones behind "compare with previous version", are not.

## Activity events

Records carry an `events` array — the same activity GitLab shows in the
project's feed:

```yaml
events:
- project_id: 42
  author_id: 12
  created_at: '2026-01-02T03:04:05.000Z'
  action: created
  target_type: MergeRequest
```

An event is stored inside whatever it refers to, which makes the set that can
appear in these files a short closed list — six actions across four kinds of
record:

| action | on |
|---|---|
| `created`, `closed`, `reopened` | an issue or a merge request |
| `merged`, `approved` | a merge request |
| `commented` | a comment, nested inside that comment |
| `created`, `closed`, `reopened` | a milestone — inside the embedded `milestone` of a work item, and in `milestones.yml` |

Push events are not among them — they belong to the project rather than to any
work item. Nothing in `events` is unique to it: an issue's `created` event says
what its `created_at` and `author_id` already say, and a `closed` event
duplicates the state change history. It is a convenience for reading, not a
source of truth.

Commit comment files hold the comment text, its author, its timestamps, and its
thread, but not reactions: the export schema does not carry award emoji for
commit comments, so a 👍 on a commit comment is not mirrored to the branch.

Threads are held together by `discussion_id`, not by position in the file — two
comments with the same `discussion_id` are one thread, however far apart they
sit. Comments are ordered by when they were written.

## Attached files are linked, not copied

This is the one place the branch is not self-contained. When you drag an image
or a document into a comment, the file is stored outside the repository and the
comment gets a link to it:

```markdown
Here is what the failure looks like:

![screenshot](/uploads/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6/screenshot.png)
```

The comment is mirrored to the branch exactly as written, link and all — but
the file behind that link is not. Clone the repository and the prose is intact
while the images are missing. If you need the files too, a full project export
includes them; the sync branch does not.

So that the gap is at least visible, each file lists what it points at:

```yaml
uploads:
- url: https://unfurl.cloud/my-group/my-project/uploads/aa11bb22cc33dd44ee55ff6600112233/deploy-failure.png
  size: 184320
  checksum: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
```

It is one list for the whole document, gathering references from the
description and from every comment in it — an image pasted into the third
comment appears here.

`url` is the address the file can actually be fetched from while this instance
is up. Note that it is not the same string as the link in the comment: what a
comment stores is `/uploads/<id>/<filename>`, which is resolved against the
project when the comment is displayed. The stored link is the tail of the URL,
so searching the file for it still finds both the comment that used the file
and its entry here.

`checksum` is a SHA256 of the file's contents, and is present only when this
instance computed one: files kept in object storage do not get one, so on many
installations it will be missing. Files attached the deprecated way, described
below, appear with a URL and nothing else.

The 32-character string in the URL is not a checksum or a hash of the file —
it is a randomly generated identifier, chosen when the file was uploaded.

Two more things follow:

- **Those links are only meaningful against this Unfurl Cloud instance.** They
  are paths, not URLs, and they resolve nowhere else.
- **The URL contains the file's access secret.** On a private project that
  secret is not enough on its own — downloading still checks that you can see
  the project. On a **public** project, or one where **Settings → General →
  Visibility → Enforce authentication checks on uploads** has been turned off,
  the secret in the link is all that is needed to fetch an image. Anyone who
  can read this repository could already read those comments, so the branch
  discloses nothing new — but see the note about mirroring under
  [Things to know](#things-to-know) before you push it somewhere else.

Older comments may instead carry an `attachment` key with a URL in it. That is
a deprecated mechanism GitLab replaced years ago, and it behaves the same way:
the reference is mirrored, the file is not. Those are listed in `uploads`
alongside the rest, with a URL only — they carry no identifier this project can
look a size or a checksum up by.

## Confidential issues and private comments

Work items sync follows your project's visibility, so it never exposes anything
to someone who could not already see it:

**Confidential issues and internal notes are not synced, on any project.** That
is the default everywhere, whatever the project's visibility, because anything
committed to the branch stays readable in its history even after the file is
deleted.

- On **private** projects you can opt in with **Also sync confidential
  content** in the settings section. Everyone who can read the repository is
  already a Reporter or above and can see confidential issues anyway. Turn this
  on only if the repository is meant to hold that content permanently — see the
  warning below.
- On **public and internal** projects there is no opt-in. The setting is shown
  cleared and cannot be changed.

If you mark an existing issue confidential, or turn the opt-in back off, the
affected files are deleted from the branch on the next sync.

This extends to mentions. When a confidential issue refers to an ordinary one,
Unfurl Cloud records that on the ordinary issue as "mentioned in issue #7" —
and hides it in the interface from anyone who cannot see #7. A file on a branch
has nobody to hide it from, so those notes are left out too; otherwise the
branch would tell every reader that #7 exists.

Mentions of work in **other projects** are kept only when the other project is
reachable by everyone who can read this repository:

- On a **public or internal** project, the other project must be at least as
  visible, and must not keep its issues or merge requests for members only.
- On a **private** project, another private project is kept when it sits under
  the same top-level group — the same owner's material — and left out when it
  belongs to someone else.
- A mention of a project that has since been renamed or deleted is left out,
  since there is no longer anything to check it against.

## Deleting a file does not erase it

A file removed from the branch is removed from the *latest* commit only. The
content is still there in every earlier commit, readable by anyone who can read
the repository:

```shell
git show <older-commit>:issues/42.yml
```

This is why confidential content is left out by default rather than cleaned up
later. It also means the opt-in above is a decision about the repository's
permanent history, not just about what is on the branch today.

## When confidential content stops being allowed

Because deleting a file does not erase it, the branch is **deleted and rebuilt
from scratch** whenever a project stops syncing confidential content. The
rebuild is a new orphan branch holding only what is currently allowed, so the
old commits are no longer on any branch.

Only this installation's own history goes. Any other installation's directory
on the branch is carried across into the rebuilt branch unchanged: it was
published by them, this project only holds it, and dropping it would delete
every copy this project has of their items — over a setting that has nothing
to do with them.

This happens automatically in two cases:

- The project's visibility changes from private to internal or public.
- Someone clears **Also sync confidential content** in the settings, or sets
  `sync_confidential=false` through the API.

What gets rebuilt afterwards depends on whether sync is still enabled. If it is,
a fresh branch is built containing everything except the confidential content.
If sync was turned off as part of the same change, the branch is deleted and
simply not rebuilt.

Turning sync off by itself, leaving the opt-in selected, purges nothing: the
project is still private, so the branch keeps exactly the audience it already
had.

What this does **not** reach:

- **Copies that already left.** Anyone who cloned, forked, or mirrored the
  repository keeps what they pulled. Nothing on the server can change that.
- **Objects pending cleanup.** Deleting the branch makes the old commits
  unreachable, but the objects themselves survive until repository housekeeping
  prunes them, and can still be fetched by exact commit SHA in the meantime.
- **Visibility changed outside the normal path.** The rebuild is triggered by
  the project update service, so a change written straight to the database or
  made from a console does not fire it. Run
  `OC::WorkItems::FullSyncWorker.perform_async(project_id, true)` to force it.

Group visibility is *not* one of these gaps. Making a group public does not
change the visibility of the projects inside it — a private project in a public
group stays private — so no project becomes readable without its own update
going through the service above.

The safest position is not to rely on the rebuild at all: leave confidential
content out of the branch unless the repository is meant to hold it permanently.

## Bringing in another installation's items

Push the `gitlab-work-items` branch from another Unfurl Cloud installation to
this project, name that installation in the branch's `sync.yml`, and the issues
and merge requests it carries are copied here as read-only items. There is no
configuration to exchange, no tokens, and no network path between the two
installations. The branch travels the way a branch travels, and it carries the
arrangement with it.

**Nothing is imported that `sync.yml` does not ask for.** A branch usually
holds directories for several installations, and arriving on this one is not a
request to be copied here: a directory can reach a branch through a fork, a
mirror, or a merge that nobody thought of as a decision. Say which
installations you mean, in a file at the root of the branch:

```yaml
---
_schema: sync@1

staging:
  uuid: 1111-2222-3333-4444-555555555555

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      import: all
```

Each top-level block names an installation — the name is yours to choose and
means nothing outside this file; the `uuid` is what identifies it, and matches
its directory on the branch. An installation finds its own block by that uuid
and reads the `sync:` entries under it. Above, `prod` copies everything in
`staging`'s directory, and `staging` copies nothing.

Keys beginning with `_` belong to the format. **Keys beginning with `.` are
yours** — put whatever you like under them, at any level, and nothing will read
them. Use those rather than YAML comments for anything you want to keep, since
comments do not survive a file being rewritten.

Withdrawing an entry stops copies being updated. It does not delete them:
removing the installation's directory from the branch is what means that.

**Any syntax error in `sync.yml` refuses the push**, naming the line and the
problem:

```plaintext
remote: GitLab: Work items sync: sync.yml:9: unknown key "improt" in "prod/sync/staging"; a peer instance section takes "import", "user_mapping", "default_user", "transfer"
```

`remote:` is Git's and `GitLab:` is added to every rejected push, neither of
which says which part of the system is talking; the rest is this check.

**A push that changes it and succeeds says what it now means:**

```plaintext
remote: Work items sync: sync.yml updated. This instance is 'prod'.
remote:   imports all from staging
```

That is what the file *asks for*, not what came of it — the import runs moments
later in the background, so nothing about the outcome is known yet. Two cases
where a perfectly valid file does nothing are called out here, because they are
otherwise invisible:

- the file names no instance with this installation's uuid, so nothing on the
  branch will be imported here;
- the person pushing is not an Owner or Planner of this project, so the push
  did not act on it at all.

A file that cannot be read is reported here too, which is the only feedback
available when it arrived by creating the branch.

Everywhere else, this feature treats the branch as data and never fails a push
over it. This file is the exception, because it is the one thing here a person
writes by hand — and the push is the only moment that person is still present.
A directive that silently meant nothing would surface much later, as a copy
that never appeared, with nothing to connect it to the typo that caused it.

Only what the file itself decides is checked: its syntax, its keys, and
arrangements that contradict each other — the same instance declared twice, a
`sync` entry naming an installation the file does not declare, an installation
syncing with itself. Anything that depends on the state of an installation
(does that user exist, is that item still here) is not, because the other side
cannot see it and it may become true later. Runs wait for those.

One consequence is worth knowing before upgrading two installations at
different times: **an installation refuses a `_schema` it does not recognise.**
If a newer one starts writing `sync@2`, pushing that branch to an older one is
rejected until it is upgraded too. Nothing already on the branch is affected —
only the push that introduces the newer file.

Two cases are deliberately not checked: a push that leaves the file untouched,
and one that *creates* the branch. The second is how a rebuild restores the
branch after confidential content stops being allowed — it deletes the branch
and re-commits everything on it — and a check able to refuse that would take
every installation's directory with it. A file that arrives that way is inert
rather than dangerous: a run that cannot read it imports nothing.

**The person pushing must be an Owner or Planner of this project.** If they
are not, the push still succeeds and nothing is imported — the branch is data,
and importing it is a privileged reading of that data, so the two are kept
apart. Failing the push would report a permissions problem the pusher cannot do
anything about. The skip is recorded in the application log; nothing appears in
the interface.

That is the threshold because importing does what only those roles can already
do: an import applies an update by deleting the local copy and rebuilding it,
and deleting issues and merge requests is an Owner's or Planner's privilege.

**A successful import turns work items sync on for this project**, if it was
never explicitly set either way. A project holding copies has to publish
pointers to them and clean up after them, so it cannot sit outside the sync.
Note what that means: a push by an Owner or Planner both brings items in and
starts publishing this project's own issue history to the branch. A project where
someone has deliberately turned sync off is left alone, and nothing is
imported into it.

## What an imported item looks like

It looks like an ordinary issue or merge request that cannot be changed. A
banner at the top says it is a copy and links to the original.

- **It keeps its number when it can.** If nothing here already uses that
  number, the copy has the same one as the original, which makes the two easy
  to talk about together. If the number is taken — likely, if this project has
  issues of its own — the copy gets a new one.
- **Nobody here is its author.** Imported items belong to the Ghost User, with
  a line in the body naming who actually wrote them and when. See
  [Trusting identities](#trusting-identities) to change that.
- **Comments come across, and you cannot add more.** Commenting is blocked
  rather than discouraged: see [Updates](#updates-and-deletions) for why a
  comment added here would not survive.
- **References are rewritten to mean what they meant.** A `#7` in the original
  refers to the other installation's issue 7. Here it points at the local copy
  of that issue, under whatever number it ended up with. If that issue has not
  been imported, the reference becomes a link to the original instead — never
  left to resolve against an unrelated local item of the same number.
- **Mentions do not become mentions of whoever holds that name here.** They
  link to the profile on the source installation, unless identity trust matched
  the person to a local account.
- **Labels and milestones are created if they do not exist.** They become
  ordinary labels and milestones of this project, and will appear in its own
  `labels.yml` and `milestones.yml` as though you had made them. You did, in a
  sense.
- **Confidential issues are never imported**, whatever the source installation
  chose to publish.
- **An item this project already has is recognised, not copied.** If a
  document has the same number *and* the same creation time as an item here,
  the two are the same item: it is recorded as such and nothing is built. This
  is for installations that began as a copy of another — a staging environment
  cloned from production, database included — where importing would otherwise
  duplicate every shared issue into an original and a ghost-authored copy that
  can never be reconciled.

  Nothing about a recognised item changes: it stays yours, stays editable, and
  is not overwritten when the other installation edits their copy. **Your copy
  wins, and it is not a merge** — deciding between two versions of the same
  item needs a policy this does not have. If they delete their copy, only the
  record of the connection goes.

  The creation time is what makes it identity: two installations both having an
  issue 42 is ordinary, and those get separate copies as before.
- **A merge request waits for its commits.** If the commits its diff is built
  from are not in this repository, it is recorded but not created, and tried
  again on every later run. They often arrive in a later push.

## Updates and deletions

An update on the source is applied by **rebuilding**: the local copy is deleted
and made again from the new file. This is why nothing you add to a copy
survives — the copy that held it no longer exists. It is also why commenting is
blocked rather than left to disappoint you later.

Deleting an item on the source deletes the copy here. So does making it
confidential.

Normally each push brings its own changes in. A nightly job also re-runs the
import for installations this project already holds copies of, which catches
anything a failed or interrupted run missed, and picks up merge requests whose
commits have since arrived. It never imports from an installation this project
has not imported from before — otherwise it would be a way around the role
check on a push — and, like every run, only from installations `sync.yml`
currently names.

## Trusting identities

An imported item is attributed to a local account when the person can be
matched here, and to the Ghost User with a byline naming them when they cannot.
How hard to look is one setting with three levels, because the two ways of
matching are the same question asked with less and less confidence:

| Level | Matches on |
|---|---|
| `none` | nobody — everyone becomes the [default user](#where-unmatched-people-end-up) |
| `email` | a published public email address. **The default** |
| `username` | that, and failing it, a matching username |

**A published address is a real signal.** Both installations only let someone
publish an address they have confirmed, so a match means the two accounts
proved the same mailbox. That is why it does not wait to be asked for.

**A username match is a matching string and nothing more.** Names can be
released and taken by someone else, and the match does not care whether the
local account is a person, a bot, or an administrator. That is why it is a
level of its own rather than something that arrives with the strong one.

Do not read `username` as a rare tiebreak. `ids.yml` records a public email
only for people who chose to publish one, so for everyone else the username is
not the second attempt — it is the only one. At that level, expect it to be
the usual path.

Be clear about what any level above `none` permits. `ids.yml` is written by
whoever pushes the branch, so **an Owner or Planner can put a published
address in it and have imported content attributed to whoever holds that
address here.** That is a capability they do not otherwise have. `none` is how
a project declines it.

Changing the level is not retroactive. Items already imported keep the
attribution they were given until the next time their source file changes and
they are rebuilt.

The level is declared per relationship in `sync.yml`, as `user_mapping`, so an
installation that knows one peer's people and none of another's can say so:

```yaml
prod:
  uuid: 2222-...
  sync:
    staging:
      import: all
      user_mapping: username
```

### Where unmatched people end up

Everyone the matching could not place becomes the Ghost User, unless the
relationship names somebody else:

```yaml
      default_user: import-bot
```

That account becomes the author *and the assignee* of whatever the peer
attributed to people who have no account here — so it should usually be a
service or bot account rather than a colleague. The byline is unaffected: an
item still says who really wrote it.

Two rules apply to the named account:

- It must be a member of this project, through the project, a group, or an
  invited group — or be an administrator. Bots qualify, including a project
  access token's bot user.
- Until it exists and qualifies, **nothing is imported from that peer.** The
  import waits rather than falling back to the Ghost User, and picks up by
  itself once the account is created or added. Look for
  `work items import waiting: default_user cannot be used` in the log.

Prefer a service *user* over an access token's bot for anything long-lived: a
token's bot is deleted with the token, and everything it authored re-attributes
to the Ghost User.

`<ghost>` is a value of `default_user` and nothing else. It says the Ghost User
explicitly, and means the same as leaving `default_user` out.

## What importing does not protect

- **Skipping confidential items is not a confidentiality boundary.** The
  importer refuses to copy them, but they are still *in the branch* — anyone
  who can read this repository can read them with `git show`. What protects
  confidential content is the decision not to publish it, made on the
  installation that owns it.
- **Branches carry other installations' directories onward.** Fetching a branch
  brings every installation's directory in it, and pushing that branch on
  carries them further. An Owner or Planner pushing a branch they fetched from
  somewhere else may be importing from an installation they have never heard
  of. Their items are imported first-hand from their own directory, with their
  own
  identities and their own links — but nobody vouched for them beyond the
  person who pushed.
- **Copies are only as current as the last push.** There is no polling and no
  connection between installations. If the chain of pushes stops, the copies
  here quietly stay as they are, and nothing indicates how old they are.

## Moving ownership to another installation

Copies are permanent, but ownership does not have to be. An issue created on
one installation can be made to *belong* to another: real and editable there,
read-only here, with this installation keeping a copy that follows it from then
on. The case this exists for is retiring a staging installation into a
production one.

The same file says so. Under the block of the installation **giving** the item
away:

```yaml
staging:
  uuid: 1111-2222-3333-4444-555555555555
  sync:
    prod:
      transfer: all          # or a list: [issues/42.yml]

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      import: transferred
```

`transfer` is written by the side losing the item, and its paths are relative
to that side's own directory. The receiving side must declare an `import` from
the giver, or **the push is refused**: without one, items would be frozen on
one installation and never appear on the other.

`import: transferred` takes only what the other installation currently
transfers, rather than mirroring everything it has. That is usually what you
want here, and it is what makes the clone case safe.

### What happens, and in what order

Nothing is negotiated between installations, and neither waits for the other.
Each acts on its own copy of the branch when a push arrives:

1. **Push to the giver.** Its items are frozen at once: read-only, with a
   banner saying where they are going. This does **not** wait for the other
   installation to take them — the gap between the two pushes can be days, and
   an edit made in it would be silently overwritten later.
1. **Push to the receiver.** It imports the items normally and takes ownership
   of them: they become editable there, and its next sync publishes them as
   full documents rather than pointers.
1. **Fetch the receiver's branch and push it to the giver.** Seeing its own
   items published by their new owner, the giver replaces each frozen original
   with an ordinary copy of the new document — keeping the original's number,
   so every link ever written to `.../issues/42` still resolves to it.

**Push to the giver first.** Edits made there after the declaration was written
but before it arrives are superseded by whatever the new owner publishes.

Until step 3, the giver's items sit frozen. That is safe and can last
indefinitely, but nothing else can be done with them in the meantime.

### Things that are deliberately not possible

- **A transfer cannot be undone.** Deleting the declaration afterwards does
  nothing, and neither does declaring the reverse: an installation never gives
  back an item it was given, and never re-freezes one it has taken. The only
  exits are completing the transfer or an administrator intervening. This is
  what makes a declaration safe to leave in the file after it has been
  satisfied — and re-reading a satisfied one is exactly what happens on every
  push from then on.
- **Merge requests cannot be transferred.** Naming one is a rejected push, and
  `transfer: all` covers issues only.
- **Confidential issues cannot be transferred**, since they were never
  published for the other side to take. Both sides refuse them, so neither
  waits on the other.
- **An item cannot be promised to two installations.** That is a rejected push
  rather than something resolved by precedence.

### Two things worth expecting

**`transfer: all` keeps meaning what it says.** An issue filed *after* the
declaration lands is transferred too, on the runs that follow — which is what
makes it usable for emptying an installation, and a surprise if you left one
in the file. Delete it once the migration is done.

**Other installations see the item move.** An installation mirroring both sides
watches the item disappear from one directory and reappear in the other, and
rebuilds its copy under a new local number. Links on that third installation
re-resolve on the next run.

## sync.yml in full

Every key the file has, in one example — `staging` handing its issues to `prod`
and going away:

```yaml
---
_schema: sync@1              # required; sync@1 is the only value
_metadata: {}                # reserved for the format; nothing reads it today

staging:                     # a name you choose, meaningful only inside this file
  uuid: 1111-2222-3333-4444-555555555555   # required; names the directory on the branch
  .note: retiring this after Q3            # unknown keys beginning with "." are ignored, at any
                                           # level, instead of being an error
  sync:
    prod:                    # another name this file declares
      transfer: all          # or a list: [issues/42.yml, issues/57.yml]

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      import: all                # or: transferred
      user_mapping: username     # or: none, email — email if left out
      default_user: import-bot   # or: <ghost>, which is what it means if left out
```

That is all of it: an installation block per installation, a `sync` entry per
relationship, and four keys inside one. An installation with nothing to say
about anybody needs only its `uuid`.

`sync` with nothing under it, or a relationship with nothing under it, declares
nothing rather than being a mistake. A key given an empty value where one is
required — `uuid:` — is a syntax error.

Keys beginning with `_` belong to the format, and the two above are all of
them. Any other `_` key is a syntax error, so use a `.` prefix for your own.

Anchors, aliases and `<<` merge keys work as YAML defines them, and a `.` key
is where to keep what you share:

```yaml
.common: &common
  import: all
  user_mapping: username

prod:
  uuid: 6666-7777-8888-9999-000000000000
  sync:
    staging:
      <<: *common
      default_user: import-bot
```

A key written out wins over one merged in, so that relationship imports
everything, matches on usernames, and sends the rest to `import-bot`.

These are syntax errors too, and like any syntax error here they refuse the
push, naming the line:

- a key that is not one of the above, or the same key twice in one mapping;
- a value outside the list for its key — `import: everything`, say;
- an alias naming an anchor the file does not define, or the same anchor
  defined twice;
- a `default_user` that is not a well-formed username, or a keyword other than
  `<ghost>` — its shape only, never whether that account exists here;
- a transfer path that is not `issues/<number>.yml` relative to the giver's own
  directory, or that names a merge request;
- an installation syncing with itself, or with a name the file does not
  declare;
- two installations sharing a `uuid`;
- the same item promised to two installations;
- a `transfer` the receiving installation declares no `import` for.

Everything that depends on an installation's state waits instead of failing:
whether the `default_user` exists, whether an item is still here, whether the
other installation has pushed yet.

## Forks

Forking copies the repository but not the issues, so a fork would otherwise
start life with a branch describing the parent project's work items. The
inherited branch is deleted when the fork is created. The fork builds its own
branch the first time one of its own work items changes.

A merge request from a fork records the source project's ID, and `ids.yml`
resolves it to a path only when that project is one a reader of this repository
could have found anyway.

## Things to know

- **Editing your own files does nothing.** The directory this installation
  writes is generated output: editing a YAML file in it and pushing does not
  change the issue, and your edit is overwritten the next time that item
  changes. Two things you push *do* have an effect: another installation's
  directory, and `sync.yml` — see
  [Bringing in another installation's items](#bringing-in-another-installations-items).
- **No pipelines run** for the `gitlab-work-items` branch, including for commits
  you push to it yourself.
- **Each sync commit records where it came from** in Git trailers:
  `Unfurl-Cloud-Version` (the same value the help page shows as "Current
  Version"), `Unfurl-Cloud-Instance` (the installation's ID and URL, so a
  branch that has been mirrored or restored elsewhere can be traced back), and
  `Work-Items-Export-Schema`. `git log --format=%B` shows them; there is also a
  `Work-Items-Synced-Through` on commits made by a full rebuild, which is
  internal bookkeeping for the nightly job.
- **Sync commit messages never create references.** A `#123` in one does not
  link to issue `#123` or leave a "mentioned in commit" note anywhere.
- **Group labels and milestones are included**, both in the work items that use
  them and in `labels.yml` / `milestones.yml`. Each is marked with the group it
  belongs to, so you can tell an inherited one from the project's own. A group
  label's priorities are trimmed to this project's — what other projects have
  done with a shared label is not recorded here.
- **Webhooks and push mirroring still fire** for sync commits. If you mirror this
  repository to another host, either expect the sync branch to be mirrored too,
  or set the mirror to push protected branches only. Weigh that against what
  the branch carries: comments quote the access secrets of any files
  [attached to them](#attached-files-are-linked-not-copied), so mirroring the
  sync branch somewhere with a wider audience than this project hands those
  secrets to that audience — while the files themselves stay behind, on this
  instance.
- **Some changes appear on a delay.** Editing a label's name or color, editing a
  milestone, and changes to the project itself (renaming, changing visibility)
  are picked up by a nightly job rather than immediately.
- **A renamed user or group reaches `ids.yml` on the next sync**, whichever
  reason causes it. Neither rename touches a work item, so on a project with no
  other activity the map can go on showing the old name for a while. What it
  says was true when it was written, which is what makes reading it alongside
  the commit it belongs to the reliable way to use it.
- **If the branch is protected** in a way that blocks the project owner from
  pushing to it, sync stops silently. Check your protected branch rules if the
  branch stops updating.
- Merge requests that target or come from `gitlab-work-items` itself are never
  synced.

## Administration

A nightly job (02:15 by default) re-syncs every enabled project that may have
drifted, and removes files for items that no longer exist. Projects with nothing
newer than their last sync commit are skipped entirely.

For the rest, it normally only looks at the issues and merge requests that have
changed since the last sync, so a busy project with ten thousand issues costs
roughly what its day's activity costs rather than ten thousand serializations
every night. It falls back to rebuilding everything when it has to — when a
label, a milestone or the project itself changed, since those are copied into
every file that references them, or when the branch has no record of how far
the last run got.

A second job (Sunday 03:15, at the lowest priority) rebuilds a project
completely, ignoring timestamps. A handful of changes move no timestamp the
nightly job can see — a deleted comment, an added or removed reaction — so if
the immediate sync for one of those ever fails, this is what puts it right. It
runs for a project once after each spell of activity rather than every week
forever, so a project nobody has touched in a year is left alone.

Both jobs decide whether a project is worth looking at before reading anything
from its repository, so a dormant project costs a few database queries and
nothing else. Neither ever commits a file whose contents have not changed.

To force a full re-sync of a project immediately, run in the Rails console:

```ruby
OC::WorkItems::FullSyncWorker.perform_async(project_id)
```

Sync can also be toggled through the API:

```plaintext
POST /api/v4/projects/:id/work_items_sync?enabled=true
```
