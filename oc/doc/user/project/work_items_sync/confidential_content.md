---
title: Confidential content in work items sync
---

[Work items sync](../work_items_sync.md) follows your project's visibility, so it never
exposes anything to someone who could not already see it.

Confidential issues and internal notes are not synced, on any project. This
default applies whatever the project's visibility, because anything committed to
the branch stays readable in its history even after the file is deleted.

- On private projects, a Maintainer can turn on syncing confidential content.
  Everyone who can read the repository is already a Reporter or above and can
  see confidential issues anyway. Turn it on only if the repository is meant to
  hold that content permanently.
- On public and internal projects, you cannot turn on syncing confidential
  content. The **Also sync confidential content** checkbox is shown cleared and
  cannot be changed.

If you mark an existing issue confidential, or turn off syncing confidential
content, the affected files are deleted from the branch on the next sync.

## Turn syncing confidential content on or off

Prerequisites:

- You must have the Maintainer role for the project.
- The project must be private. On public and internal projects, the checkbox is
  cleared and disabled.

To turn syncing confidential issues and internal notes on or off:

1. In the top bar, select **Search or go to** and find your project.
1. In the left sidebar, select **Settings** > **General**.
1. Expand **Work items sync**.
1. Select or clear the **Also sync confidential content** checkbox.
1. Select **Save changes**.

Clearing the checkbox deletes the affected files on the next sync and rebuilds
the branch. For details, see
[When syncing confidential content stops](#when-syncing-confidential-content-stops).

## Mentions

When a confidential issue refers to an ordinary one, Unfurl Cloud records that
on the ordinary issue as "mentioned in issue #7" and hides it in the interface
from anyone who cannot see #7. A file on a branch has nobody to hide it from, so
those notes are left out too. Otherwise the branch would tell every reader
that #7 exists.

Mentions of work in other projects are kept only when the other project is
reachable by everyone who can read this repository:

- On a public or internal project, the other project must be at least as
  visible, and must not keep its issues or merge requests for members only.
- On a private project, another private project is kept when it is under the
  same top-level group, which is the same owner's material. It is left out when
  it belongs to someone else.
- A mention of a project that was renamed or deleted is left out,
  because there is nothing left to check it against.

## Deleting a file does not erase it

A file removed from the branch is removed from the latest commit only. The
content is still in every earlier commit, readable by anyone who can read the
repository:

```shell
git show <older-commit>:<installation-uuid>/issues/42.yml
```

For this reason, confidential content is left out by default rather than cleaned
up later. Turning on syncing confidential content is a decision about the
repository's permanent history, not just about what is on the branch today.

## When syncing confidential content stops

Because deleting a file does not erase it, the branch is deleted and rebuilt
from scratch whenever a project stops syncing confidential content. The rebuild
is a new orphan branch holding only what is allowed, so the old
commits are no longer on any branch.

Only this installation's own history goes. Any other installation's directory on
the branch is carried across into the rebuilt branch unchanged.

The rebuild happens automatically in two cases:

- The project's visibility changes from private to internal or public.
- Someone clears **Also sync confidential content** in the settings, or sets
  `sync_confidential=false` through the API.

What happens afterward depends on whether sync is still on:

- If sync is still on, a fresh branch is built containing everything except
  the confidential content.
- If sync was turned off as part of the same change, the branch is deleted and
  not rebuilt.

Turning sync off by itself, with **Also sync confidential content** still
selected, purges nothing. The project is still private, so the branch keeps the
audience it already had.

### What the rebuild does not reach

- Copies that already left. Anyone who cloned, forked, or mirrored the
  repository keeps what they pulled. Nothing on the server can change that.
- Objects pending cleanup. Deleting the branch makes the old commits
  unreachable, but the objects survive until repository housekeeping prunes
  them, and can still be fetched by exact commit SHA in the meantime.
- Visibility changed outside the standard path. The rebuild is triggered by the
  project update service, so a change written straight to the database or made
  from a console does not start it. An administrator can force the rebuild. For
  details, see [Work items sync administration](../../../administration/work_items_sync.md).

Group visibility is not one of these gaps. Making a group public does not change
the visibility of the projects inside it. A private project in a public group
stays private, so no project becomes readable without its own update going
through the service.

The safest position is not to rely on the rebuild at all. Leave confidential
content out of the branch unless the repository is meant to hold it permanently.

## Skipping confidential items on import is not a boundary

The importer refuses to copy confidential items, but they are still in the
branch and readable with `git show`. For details, see
[Import work items](import.md).
