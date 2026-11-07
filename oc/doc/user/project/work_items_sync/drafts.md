---
title: Create issues offline with drafts
---

Create issues without opening the interface by pushing draft files to the
`work-items-sync` branch. Each draft is a small YAML file. A few seconds after
you push, Unfurl Cloud creates an issue from it, publishes the issue on the
branch, and deletes the draft. Drafts can refer to each other, so you can
create a set of linked issues in one push.

For an overview of the feature, see [Work items sync](../work_items_sync.md).

## Create issues from drafts

Prerequisites:

- You must have the Developer role or higher for the project.
- [Work items sync](../work_items_sync.md#turn-work-items-sync-on-or-off) must be
  turned on for the project. While it is off, drafts wait on the branch and the
  first push after you turn it on creates them.
- You need a local clone of the repository with the `work-items-sync` branch
  checked out, for example
  [in its own worktree](../work_items_sync.md#check-out-the-branch-in-its-own-worktree).

To create issues from drafts:

1. Find the ID of your installation. In the top bar, select **Search or go to**
   and find your project. In the left sidebar, select **Settings** > **General**,
   then expand **Work items sync**. The ID is shown as "This installation's ID,
   for sync.yml:".
1. On the `work-items-sync` branch, open the `_incoming` folder inside the
   folder named with that ID.
1. In `_incoming`, add one file for each issue, named `<key>.yml`. To start
   from the example in that folder, copy `example.yml.sample` to
   `<key>.yml`. For the rules for the key, see [Draft keys](#draft-keys).
1. Write the draft. For the keys you can use, see
   [Draft format](#draft-format).
1. Commit and push the branch.

   The push output tells you what Unfurl Cloud is about to try. For example:

   ```plaintext
   Work items sync: 2 drafts will be created (fix-login, session-cache)
   ```

1. About 10 seconds later, pull the branch and merge the installation's commit.
   Each issue is in `<uuid>/issues/<number>.yml`, and the draft files are gone.

If a draft is malformed, the push is refused. For details, see
[Push errors](#push-errors).

### Example

This example creates two issues that refer to each other. The first file is
`<uuid>/_incoming/fix-login.yml`:

```yaml
_schema: issue_draft@1
title: Login fails after password reset
description: |
  Probably caused by #draft:session-cache.
labels: [bug, auth]
assignees: [jane]
due_date: 2026-12-01
```

The second file is `<uuid>/_incoming/session-cache.yml`:

```yaml
_schema: issue_draft@1
title: Stale sessions survive a password reset
description: |
  Blocks #draft:fix-login.
labels: [auth]
```

After the push, the installation creates both issues. If they become issues
`#51` and `#52`, the first description reads `Probably caused by #52.` The
installation also commits `<uuid>/drafts.yml`:

```yaml
_schema: drafts@1
drafts:
  fix-login: 51
  session-cache: 52
```

## Draft keys

The key is the file name without its extension. Use it to refer to the draft
from other drafts.

- A key has lowercase letters, digits, `-`, and `_`. It starts with a letter or
  digit and has at most 64 characters. Any other key refuses the push.
- Only files that end in `.yml` or `.yaml` are drafts. Other files in
  `_incoming`, such as `README.md`, `example.yml.sample`, or editor backups,
  are ignored.
- Subfolders of `_incoming` are ignored.
- `x.yml` and `x.yaml` side by side have the same key, and the push is refused.

A key is used once. If a draft with a key that was already used appears again,
for example an old copy that you merge back, it is deleted and not created
again. This is true even if the issue was deleted. To create a new issue, use a
new key.

Only the installation that owns the folder creates the issue. Other
installations that have the branch ignore the draft.

## Draft format

A draft has these keys:

| Key            | Required | Description |
|:---------------|:---------|:------------|
| `_schema`      | Yes      | Must be `issue_draft@1`. |
| `title`        | Yes      | One line, at most 255 characters. |
| `description`  | No       | Markdown text. |
| `labels`       | No       | List of label names. |
| `milestone`    | No       | Milestone title. |
| `assignees`    | No       | List with one username. |
| `due_date`     | No       | Date in `YYYY-MM-DD` format. |
| `confidential` | No       | `true` or `false`. |
| `type`         | No       | `issue`, `task`, or `incident`. The default is `issue`. |

Keys that start with a period, such as `.note`, are yours. They are ignored, so
you can use them for notes to yourself.

The push is refused for:

- Unknown keys.
- Keys that start with `_`, other than `_schema`.
- Duplicate keys.
- YAML anchors and aliases.
- A file larger than 64 KiB.

There is no limit on the number of drafts in a push.

## References between drafts

Write `#draft:<key>` in a description to refer to another draft. When the
drafts are created, each reference becomes `#<issue number>`.

- The order of the drafts does not matter. Drafts can refer to each other and
  to themselves.
- A key from an earlier push that was already created also works.
- A `#draft:<key>` in a code span or fenced code block is left as written.
- A `#draft:<key>` that names a key that is neither a draft on the branch nor
  already created refuses the push.
- A plain reference such as `#42` works as usual.

## Permissions

The author of the issue is the person who pushed, not the author of the
commit. That person needs permission to create issues, which in practice is the
Developer role, because pushing to the branch needs it.

- Labels, milestone, assignees, and due date need permission to set issue
  metadata. Developers have it.
- A label or milestone that does not exist is created if the person who pushed
  may create labels or milestones. Otherwise the draft is not created.
- An assignee must exist and be able to see the project. A draft can have only
  one assignee.
- `confidential: true` is accepted only on private projects. On other projects
  the push is refused. If the project became public before the draft was
  created, the draft is not created. For more information, see
  [Confidential content in work items sync](confidential_content.md#drafts).

## Push errors

The push is refused for a malformed draft. The message names the file and line:

```plaintext
Work items sync: <uuid>/_incoming/fix-login.yml:2: unknown key "titel"
```

Fix the file and push again. Deleting a draft is never refused, so that is how
you cancel one.

After a push that adds or changes a draft, the output describes what Unfurl
Cloud is about to try. It does not report the outcome.

```plaintext
Work items sync: 2 drafts will be created (fix-login, session-cache)
Work items sync: 1 draft already created and will be removed (old-one)
Work items sync: draft nobody cannot be created by you: no user nobody-here can be assigned here
Work items sync: drafts are not created while work items sync is off for this project
```

A draft that cannot be created stays on the branch and is reported again on
each push. Fix it and push again.

## Pull before you push again

The installation commits the new issue files and deletes the drafts in the same
commit. Merge that commit into your copy before your next push, then push
normally.

If you edited a draft after you pushed it, Git reports a conflict because the
installation deleted the file. Delete your copy to resolve it.

Do not force push. For why, see
[Import work items from another installation](import.md).

## Drafts are not private

Draft text stays in the branch history, even after the draft is deleted.
Anyone who can read the repository can read drafts. Do not put secrets in a
draft.

## Related topics

- [Work items sync](../work_items_sync.md)
- [Work items sync file format](file_format.md)
- [Confidential content in work items sync](confidential_content.md)
- [Import work items from another installation](import.md)
- [Work items sync configuration file](sync_yml.md)
- [Work items sync administration](../../../administration/work_items_sync.md)
