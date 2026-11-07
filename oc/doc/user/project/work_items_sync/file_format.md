---
title: Work items sync file format
---

The `work-items-sync` branch has no code on it. It holds only work item files,
all under a directory named for the installation that wrote them, and one file at
the root that nobody generates.

Each work item file follows the same structure as an Unfurl Cloud project
export. For what an export holds, see
[Migrate GitLab data by using file exports](../settings/import_export.md).

## Branch layout

```plaintext
sync.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/issues/1.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/issues/2.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/merge_requests/1.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/commit_notes/f0c7d1a94e3b6528d0b1f4a27c9e83b5d6a10f42.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/labels.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/milestones.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/ids.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/drafts.yml
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/_incoming/README.md
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/_incoming/example.yml.sample
9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43/_incoming/fix-login.yml
```

The first path segment is the UUID of the installation. Everything below it
is described relative to that directory.
The directory lets the branch hold the work items of more than one installation.
If you fetch this branch into a project on another Unfurl Cloud installation
and push its own sync on top, the two sets of files sit side by side instead of
colliding at `issues/1.yml`.
Each installation only ever writes to, and cleans up, its own directory.

`sync.yml` is the only file meant to be edited by hand, apart from some fields
of issue files that you can [edit offline](offline_edits.md).
It sits outside every installation directory because it describes an arrangement
between installations, not the contents of one.
No installation writes it, and none deletes it.
For its keys, see [Work items sync configuration file](sync_yml.md).

The number in an `issues/` or `merge_requests/` filename is the issue or merge
request number as it appears in the interface, so `issues/42.yml` is issue
`#42`.
Comments left on a commit are grouped by the SHA of that commit, so
`commit_notes/<sha>.yml` holds every comment on that one commit.

`labels.yml` and `milestones.yml` are catalogs of the whole vocabulary of the
project, including everything it inherits from the groups above it.
Each work item file already carries a full copy of the labels and milestone it
uses, so the catalogs cover what the work items do not mention:

- A label nobody has applied yet.
- A milestone with nothing in it.
- The description and dates of a milestone whose issues are all closed.

The nightly job rewrites them, not the moment you rename something.

Two more paths relate to creating issues offline:

- `<uuid>/_incoming/` holds drafts waiting to be created. You write these
  files. The commit that creates the branch adds a `README.md` and an
  `example.yml.sample` draft to copy, so the folder exists before the first
  draft. They are not added again if you delete them. For details, see
  [Create issues offline with drafts](drafts.md).
- `<uuid>/drafts.yml` lists each draft key and the issue number it became. It
  starts with `_schema: drafts@1`, followed by a `drafts:` mapping of key to
  number.

## Reference files for imported items

An issue or merge request imported from another Unfurl Cloud installation is a
read-only copy. For how items get imported, see
[Import work items from another installation](import.md).
Its file says that it is a copy and does not repeat the contents:

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

The file sits at the path a standard file would.
Anyone reading the branch can tell that the item exists here, and where the
original lives, without this project appearing to be the source of something it
only mirrors.
Without that, fetching a branch between installations would multiply the same
issue into a copy per installation, each looking equally original.

The `_schema` line tells the two kinds of file apart: `issues@1` holds an issue,
and `issue_reference@1` points at one.

The `ids` block reads `local ID: source ID`.
Both installations publish an `ids.yml`, and between them the two files explain
every ID either installation uses.
Neither says that user 12 on the source installation and user 500 on this one
are the same person.
This installation decided that while importing, by matching a verified public
email or a username, and the `ids` block is where it is written down.

The block is absent when nothing was matched. In that case everyone in the item
was someone this installation could not place, so every one of them is the Ghost
User and there is no correspondence to record.
For what it takes to match someone, see
[Import work items from another installation](import.md).

## File contents

Each file holds the whole item, including its comments.
This example is abridged. A real file has more fields:

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

Fields with nothing in them are left out instead of written as empty.
A file holds what the item says, not the full list of everything an item could
have. A missing key means "not set". Omitting empty fields roughly halves the
length of a typical merge request file.

### The `_schema` line

Every file starts with a `_schema` line so a program reading the branch can tell
what it holds without guessing from the path.
It reads `<record>@<layout>`:

- `<record>` is the kind of record the file holds: `issues`, `merge_requests`,
  or `commit_notes`.
  It is also the directory name and the name of the relation in the project
  export of Unfurl Cloud.
- `@<layout>` is the layout of the file itself. It changes only when the way a
  file is put together changes. A reader that does not recognize the number
  should stop rather than guess.

### Export schema version

The version of the export schema tells you whether the fields inside are the
ones you expect. For how versions are handled, see
[Compatibility](../settings/import_export.md#compatibility).
It is recorded on the commit, not in the file:

```shell
git log -1 --format='%(trailers:key=Work-Items-Export-Schema)' -- <installation-uuid>/issues/42.yml
```

## Included and excluded data

A file has everything needed to reconstruct the item:

- Title, description, state, author, and timestamps.
- Comments, including system notes such as "changed the description".
- Labels, milestone, assignees, and time tracking.
- Award emoji.
- The label, milestone, and state change history.

The one exception is files attached to a comment, which are
[linked rather than copied](#attached-files).

Merge request files also include reviewers, approvals, and the source and target
branches. They do not include the code changes, because the code already lives
in the same repository.
They carry the coordinates of the diff instead:

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

The three SHAs are the corners of the diff GitLab displayed, so
`git diff <base_commit_sha>..<head_commit_sha>` in this repository reproduces it
exactly, instead of approximating it against the current target branch.
The per-file patch text and the per-commit list are left out. They are 20
times the size of everything else in the file, and they describe code you
already have.
Only the current version is recorded. The older diff versions of a merge
request, the ones behind "compare with previous version", are not.

A merge request from a fork records the ID of the source project.
`ids.yml` resolves the ID to a path only when that project is one a reader of
this repository could have found anyway.

### Activity events

Records carry an `events` array, the same activity GitLab shows in the feed of
the project:

```yaml
events:
- project_id: 42
  author_id: 12
  created_at: '2026-01-02T03:04:05.000Z'
  action: created
  target_type: MergeRequest
```

An event is stored inside whatever it refers to.
The events that can appear in these files are a short closed list of six actions
across four kinds of record:

| Action | On |
|--------|----|
| `created`, `closed`, `reopened` | An issue or a merge request |
| `merged`, `approved` | A merge request |
| `commented` | A comment, nested inside that comment |
| `created`, `closed`, `reopened` | A milestone, inside the embedded `milestone` of a work item and in `milestones.yml` |

Push events are not among them, because they belong to the project and not to
any work item.
Nothing in `events` is unique to it. The `created` event of an issue says what
its `created_at` and `author_id` already say, and a `closed` event duplicates
the state change history.
The array is a convenience for reading, not a source of truth.

### Commit comments

Commit comment files hold the comment text, its author, its timestamps, and its
thread.
They do not hold reactions. The export schema does not carry award emoji for
commit comments, so a thumbs-up on a commit comment is not mirrored to the
branch.

### Threads

Threads are held together by `discussion_id`, not by position in the file.
Two comments with the same `discussion_id` are one thread, however far apart
they sit.
Comments are ordered by when they were written.

## Attached files

The attached files are the one place the branch is not self-contained.
When you drag an image or a document into a comment, the file is stored outside
the repository and the comment gets a link to it:

```markdown
Here is what the failure looks like:

![screenshot](/uploads/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6/screenshot.png)
```

The comment is mirrored to the branch exactly as written, link and all, but the
file behind that link is not.
If you clone the repository, the prose is intact and the images are missing.
A full project export includes the files. The sync branch does not.

So that the gap is visible, each file lists what it points at:

```yaml
uploads:
- url: https://unfurl.cloud/my-group/my-project/uploads/aa11bb22cc33dd44ee55ff6600112233/deploy-failure.png
  size: 184320
  checksum: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
```

The list covers the whole document. It gathers references from the description
and from every comment, so an image pasted into the third comment appears here.

- `url` is the address the file can be fetched from while this installation is up.
  It is not the same string as the link in the comment. A comment stores
  `/uploads/<id>/<filename>`, which is resolved against the project when the
  comment is displayed. The stored link is the tail of the URL, so searching the
  file for it finds both the comment that used the file and its entry in
  `uploads`.
- `checksum` is a SHA256 of the contents of the file. It is present only when
  this installation computed one. Files kept in object storage do not get one, so on
  many installations it is missing. Files attached the deprecated way, described
  later in this section, appear with a URL and nothing else.

The 32-character string in the URL is not a checksum or a hash of the file.
It is a randomly generated identifier, chosen when the file was uploaded.

Two more things follow:

- The links in comments are paths, not URLs, so they are only meaningful against
  this Unfurl Cloud installation and resolve nowhere else.
- The URL contains the access secret of the file.
  On a private project that secret is not enough on its own, because downloading
  still checks that you can see the project.
  On a public project, or one where **Settings** > **General** > **Visibility** >
  **Enforce authentication checks on uploads** has been turned off, the secret in
  the link is all that is needed to fetch an image.
  Anyone who can read this repository could already read those comments, so the
  branch discloses nothing new.
  Before you push the branch somewhere else, see the note about mirroring in
  [Work items sync](../work_items_sync.md).

Older comments might instead carry an `attachment` key with a URL in it.
GitLab replaced that deprecated mechanism years ago, and it behaves the same
way: the reference is mirrored and the file is not.
These attachments are listed in `uploads` alongside the rest, with a URL only.
They carry no identifier this project can look up a size or a checksum by.

## Sync commits

Each sync commit records where it came from in Git trailers:

- `Unfurl-Cloud-Version` is the same value the help page shows as "Current
  Version".
- `Unfurl-Cloud-Instance` is the ID and URL of the installation, so a branch
  that has been mirrored or restored elsewhere can be traced back.
- `Work-Items-Export-Schema` is the version of the export schema.
- `Work-Items-Synced-Through` appears on commits made by a full rebuild. It is
  internal bookkeeping for the nightly job.

`git log --format=%B` shows them.

Sync commit messages never create references. A `#123` in one does not link to
issue `#123` or leave a "mentioned in commit" note anywhere.

## Group labels and milestones

Group labels and milestones are included, both in the work items that use them
and in `labels.yml` and `milestones.yml`.
Each is marked with the group it belongs to, so you can tell an inherited one
from the project's own.
The priorities of a group label are trimmed to this project. What other
projects have done with a shared label is not recorded here.

## Renamed users and groups

A renamed user or group reaches `ids.yml` on the next sync, whatever the reason
for the rename.
Neither rename touches a work item, so on a project with no other activity the
map can go on showing the old name for a while.
What `ids.yml` says was true when it was written, which is why reading it
alongside the commit it belongs to is the reliable way to use it.

## The `ids.yml` file

The work item files are full of numbers such as `author_id: 12` and
`project_id: 42`.
They are database IDs, which mean nothing outside the Unfurl Cloud installation that
wrote them.
`ids.yml` is the index that turns them into something you can use:

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

`name` is the display name you see beside a comment in the interface.
The files carry it only for the author of an item or a comment. For everyone
else, such as whoever last edited something, who is assigned, or who left a
thumbs-up, `ids.yml` is where the name comes from.
`public_email` appears only for users who chose to publish one on their profile.

- `ids.yml` is a snapshot, not a permanent key.
  Owners can change usernames and paths, and a project can be renamed or moved.
  The file says what these IDs were called when it was written.
  Read the `ids.yml` of the same commit as the file you are reading, with
  `git show <commit>:<installation-uuid>/ids.yml`, and the two agree.

A project a reader of this repository could not otherwise see is left out of the
map instead of named. An example is the source project of a merge request from a
private fork.
The ID stays in the file. Nothing in `ids.yml` turns it into a path.
