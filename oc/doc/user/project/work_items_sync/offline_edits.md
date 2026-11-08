---
title: Edit issues offline
---

Change an issue without opening the interface by editing its file on the
`work-items-sync` branch and pushing. Unfurl Cloud applies your edits to the
issue as you, so notifications, webhooks, and system notes such as "changed the
title" work as usual. A few seconds later, the installation commits the file
again in its official form.

For an overview of the feature, see [Work items sync](../work_items_sync.md).

## Edit an issue offline

Prerequisites:

- You must have permission to push to the `work-items-sync` branch and to make
  the change in the issue. For example, to change labels you must be able to set
  labels.
- [Work items sync](../work_items_sync.md#turn-work-items-sync-on-or-off) must be
  turned on for the project.
- You need a local clone of the repository with the `work-items-sync` branch
  checked out, for example
  [in its own worktree](../work_items_sync.md#check-out-the-branch-in-its-own-worktree).

To edit an issue offline:

1. Find the ID of your installation. In the top bar, select **Search or go to**
   and find your project. In the left sidebar, select **Settings** > **General**,
   then expand **Work items sync**. The ID is shown as "This installation's ID,
   for sync.yml:".
1. On the `work-items-sync` branch, pull the latest commits.
1. Open the issue file, for example `<uuid>/issues/42-login-fails.yml`, where
   `<uuid>` is the ID of your installation. The file name starts with the issue
   number and a hyphen. A file with no name is `<number>.yml`.

   You can rename the file if the new name starts with `<number>-`. The
   installation keeps your name. If you rename it to `<number>.yml`, it gets a
   generated name again the next time it is written.
1. Change the fields you want. For the fields you can change, see
   [Fields you can edit](#fields-you-can-edit).
1. Commit and push the branch.

   The push output tells you what Unfurl Cloud is about to try. For example:

   ```plaintext
   Work items sync: edits to 2 issues will be applied (#42, #51)
   ```

1. About 10 seconds later, pull the branch and merge the installation's commit.
   The file now has the official form, for example a new `updated_at`.

If a file has a problem, the whole push is refused. For details, see
[Push errors](#push-errors).

## Fields you can edit

| Field | What you can do |
|:------|:----------------|
| `title` | Change it. One line, at most 255 characters. |
| `description` | Change it. |
| `state` | Set it to `opened` or `closed`. |
| `confidential` | Set it to `true` or `false`. |
| `due_date` | Set a date in `YYYY-MM-DD` format, or remove the key. |
| `label_links` | Add an entry `- label: {title: <name>}`, or remove an entry. You cannot change the other keys of an existing entry. |
| `milestone` | Replace it with `milestone: {title: <name>}`, or remove the key. You cannot change the other keys of the current milestone. |
| `notes` | Add or change comments. See [Comments](#comments). |

Assignees are read-only. To set an assignee on a new issue, use
[drafts](drafts.md). Every other key is read-only. If you change, add, or remove
one, the push is refused.

A label or milestone that does not exist is created if you may create it.
Otherwise the push is refused.

For example, this edit closes the issue and adds a label:

```yaml
state: closed
label_links:
  - label:
      title: bug
  - label:
      title: needs-review
```

## Comments

In `notes`, you can:

- Add a comment. Add an entry that has only a `note` key, anywhere in the list.
  The author and dates come from your push.
- Change a comment you wrote. Change its `note` text.

You cannot change the comments of others or system notes. Deleting a comment is
refused.

## Conflicts

A push is refused if a field you changed was also changed in Unfurl Cloud since
your copy, unless the change is the same as yours. For example:

```plaintext
Work items sync: <uuid>/issues/42-login-fails.yml: issue #42: "title" changed since your copy; pull and push again
```

Only the fields you edited are compared. A change to another field, or a new
comment on the web, does not refuse your push. Labels never conflict: each label
you add or remove is applied on its own, so a label someone else added or
removed on the web stays as they left it. An edited comment conflicts if
its text changed in Unfurl Cloud or if it was deleted.

To resolve a conflict:

1. A few seconds after the refusal, pull the branch. The installation syncs the
   issue, so you get the current version.
1. Make your edit again.
1. Commit and push.

A conflict can also appear after your push is accepted. If someone changes on
the web a field your push changes before Unfurl Cloud applies it, that issue is
skipped and none of your edits to it are applied. The issue is synced back to
the Unfurl Cloud version, which overwrites your edit in the branch. Make your
edit again. The same happens if applying the edit fails for another reason.

## Push errors

The push is refused as a whole if any edited file has a problem. The message
names the file. The reasons are:

- A read-only field changed. For example:

  ```plaintext
  Work items sync: <uuid>/issues/42-login-fails.yml: "author_id" cannot be changed offline
  ```

- The YAML or a value is invalid.
- You do not have permission. You cannot edit the issue, reopen it, set labels,
  a milestone, or a due date, change confidentiality, or comment, or the comment
  is not yours.
- The issue no longer exists.
- The push is a force push. A force push cannot edit issues: pull, merge, and
  push again.
- Work items sync is off for the project.
- The push edits more than 100 issues.
- A file is larger than 1 MiB.
- A field you changed also changed in Unfurl Cloud. See
  [Conflicts](#conflicts).

Fix the file and push again.

## What is not an edit

These changes are ignored, and the installation overwrites them:

- Adding or deleting issue files.
- A copy of an issue file. If you copy a file and edit the copy, the edit is
  ignored and the installation removes the copy. Rename the file instead.
- Edits to every other file the installation writes, including merge request
  files, `commit_notes`, `labels.yml`, `milestones.yml`, and `ids.yml`.

A rename is not ignored. If you rename an issue file to a new name that starts
with `<number>-`, the rename is applied together with any edits you made to the
file in the same push. Any other file name, such as `42_login.yml`, is not an
issue file and is ignored.

Merge requests cannot be edited offline.

Confidential issues appear on the branch only if the project
[syncs confidential content](confidential_content.md). If you set
`confidential: true` on a project that does not, the edit is applied. The next
sync then removes the file from the branch.

## Pull before you push again

Merge the installation's commit into your copy before your next push. Do not
force push. For why, see
[Import work items from another installation](import.md).

## Related topics

- [Work items sync](../work_items_sync.md)
- [Work items sync file format](file_format.md)
- [Create issues offline with drafts](drafts.md)
- [Confidential content in work items sync](confidential_content.md)
- [Work items sync administration](../../../administration/work_items_sync.md)
