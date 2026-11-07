---
title: Work items sync
---

Work items sync keeps a copy of your project's issues, merge requests, and
commit comments in the project's own Git repository, as plain YAML files on a
branch called `work-items-sync`.

When you open an issue, edit a description, leave a comment, or react with an
emoji, Unfurl Cloud commits the updated file to that branch a few seconds later.
Nothing changes about how you use issues and merge requests. The branch is a
mirror that keeps itself up to date in the background.

With work items sync:

- Clone the repository and you have the full issue history offline, in a format
  you can read, grep, and diff.
- The discussion around your code is backed up outside the database, in the
  same repository as the code. Files attached to comments are
  [linked rather than copied](work_items_sync/file_format.md#attached-files).
- Your work items are portable. The files use the same schema as the Unfurl
  Cloud project export, so they can be imported into another installation.

## Turn work items sync on or off

Blueprint and dashboard projects have work items sync on by default. Every other
project starts with it off.

Turning it on commits everything that exists already, so the first sync on a
busy project produces one large commit. Turning it off stops new commits but
leaves the branch in place.

Prerequisites:

- You must have the Maintainer role for the project.

To turn work items sync on or off:

1. In the top bar, select **Search or go to** and find your project.
1. In the left sidebar, select **Settings** > **General**.
1. Expand **Work items sync**.
1. Select **Enable work items sync** or **Disable work items sync**. If you turn
   sync on, confirm the prompt.

When you turn sync on, a `work-items-sync` branch appears in the repository a
few seconds later.

## Branch contents

The branch has no code on it. It holds one directory of work item files for each
installation that writes to it, and a `sync.yml` file at the root that you edit
by hand. The number in an `issues` or `merge_requests` filename is the number
shown in the interface, so `issues/42.yml` is issue `#42`.

For the full layout and what each file contains, see
[Work items sync file format](work_items_sync/file_format.md).

## What is synced

Each file holds the whole item, including its comments, labels, milestone, and
change history. Files attached to comments are not copied: if you clone the
repository, the text is intact and the attachments are missing. For the full
list of what each file holds, see
[Work items sync file format](work_items_sync/file_format.md#included-and-excluded-data).

## Confidential content

Confidential issues and internal notes are not synced by default. On private
projects, a Maintainer can turn on **Also sync confidential content**. For
details, see
[Confidential content in work items sync](work_items_sync/confidential_content.md).

## Import and transfer

You can bring work items from another Unfurl Cloud installation into your
project. For more information, see
[Import work items from another installation](work_items_sync/import.md).

You can also hand ownership of your work items to another installation. For
more information, see
[Transfer work items to another installation](work_items_sync/transfer.md).

Both use a `sync.yml` file on the branch. For the reference, see
[Work items sync configuration file](work_items_sync/sync_yml.md).

You can also create issues offline by pushing draft files to the branch. For
more information, see
[Create issues offline with drafts](work_items_sync/drafts.md).

## Forks

Forking copies the repository but not the issues, so a fork would otherwise
start with a branch describing the parent project's work items. The inherited
branch is deleted when the fork is created. The fork builds its own branch the
first time one of its own work items changes.

## Things to know

- Editing your own files does nothing, except for files you add under your
  installation's `_incoming/` folder, which are issue drafts. For details, see
  [Create issues offline with drafts](work_items_sync/drafts.md). The rest of the
  directory this installation writes is generated output. If you edit a YAML
  file in it and push, the issue doesn't change, and your edit is overwritten the
  next time that item changes. Two other things you push have an effect: another
  installation's directory, and `sync.yml`. See
  [Import work items from another installation](work_items_sync/import.md) and
  [Work items sync configuration file](work_items_sync/sync_yml.md).
- No pipelines run for the `work-items-sync` branch, including for commits you
  push to it yourself.
- Webhooks and push mirroring still fire for sync commits. If you mirror this
  repository to another host, either expect the sync branch to be mirrored too,
  or set the mirror to push protected branches only. Comments quote the access
  secrets of any files attached to them, so mirroring the sync branch somewhere
  with a wider audience than this project gives those secrets to that audience.
  The files themselves stay behind, on this installation. For details, see
  [Work items sync file format](work_items_sync/file_format.md#attached-files).
- Some changes appear on a delay. A nightly job picks up edits to a label's name
  or color, edits to a milestone, and changes to the project itself, such as
  renaming or changing visibility.
- If the branch is protected in a way that blocks the project owner from pushing
  to it, sync stops silently. If the branch stops updating, check your protected
  branch rules.
- Merge requests that target or come from `work-items-sync` are never synced.

## Related topics

- [Work items sync file format](work_items_sync/file_format.md)
- [Confidential content in work items sync](work_items_sync/confidential_content.md)
- [Create issues offline with drafts](work_items_sync/drafts.md)
- [Import work items from another installation](work_items_sync/import.md)
- [Transfer work items to another installation](work_items_sync/transfer.md)
- [Work items sync configuration file](work_items_sync/sync_yml.md)
- [Work items sync administration](../../administration/work_items_sync.md)
