---
title: Import work items from another installation
---

Import work items to copy the issues and merge requests of another Unfurl Cloud
installation into this project as read-only items. You push the installation's
`work-items-sync` branch to this project and name the installation in the
branch's `sync.yml`. There is no configuration to exchange, no tokens, and no
network path between the two installations. The branch carries the arrangement
with it.

Nothing is imported that `sync.yml` does not ask for. A branch usually holds
directories for several installations, and a directory can reach a branch
through a fork, a mirror, or a merge. Arriving on this installation is not a
request to be copied here.

For the other direction, see
[Transfer work items to another installation](transfer.md). For an overview of
the feature, see [Work items sync](../work_items_sync.md).

## Import work items

Prerequisites:

- You must have the Owner or Planner role in this project. See
  [Who can trigger an import](#who-can-trigger-an-import).
- Work items sync must not have been deliberately turned off for the project.
  Nothing is imported into such a project.
- You must be able to read the other installation's project, to fetch its branch.

To import work items from another installation:

1. In your local clone of this project, add the other project as a Git remote
   and fetch its `work-items-sync` branch:

   ```shell
   git remote add other-installation <other_project_url>
   git fetch other-installation work-items-sync
   ```

1. If this project already has a `work-items-sync` branch, check it out and
   merge the fetched branch into it. Each installation writes its own
   directory, so only `sync.yml` can conflict:

   ```shell
   git fetch origin work-items-sync
   git checkout -B work-items-sync origin/work-items-sync
   git merge other-installation/work-items-sync
   ```

   If this project has no `work-items-sync` branch, create it from the
   fetched branch instead:

   ```shell
   git checkout -b work-items-sync other-installation/work-items-sync
   ```

1. Add or edit `sync.yml` at the root of the branch. Name each installation by
   its UUID, and add an `import` entry under the installation that should
   receive the items.

   An installation's UUID is the name of its directory on the branch, and it
   appears in the `Unfurl-Cloud-Instance` trailer of its sync commits. To find
   this installation's UUID, with the Maintainer role in this project:

   1. In the top bar, select **Search or go to** and find your project.
   1. In the left sidebar, select **Settings** > **General**.
   1. Expand **Work items sync**.
   1. Copy the value after **This installation's ID, for sync.yml:**.

   The UUIDs in this example are placeholders:

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

1. Commit the change, and push the branch to this project:

   ```shell
   git push origin work-items-sync
   ```

Do not force push the branch. A force push replaces this project's `sync.yml`
with the other branch's version, and if `sync.yml` still names an installation
whose directory the pushed branch lacks, this project deletes its copies of
that installation's items.

In the example, `prod` copies everything in the directory of `staging`, and
`staging` copies nothing. The name of each block is yours to choose. The `uuid`
identifies the installation.

If `sync.yml` contains a mistake, the push is refused with the line and the
problem. For every key and the validation rules, see
[Work items sync configuration file](sync_yml.md).

Withdrawing an entry from `sync.yml` stops copies being updated. It does not
delete them. Removing the installation's directory from the branch deletes them.

## Who can trigger an import

The person pushing must be an Owner or Planner of the project. If they are not,
the push still succeeds and nothing is imported. The push message says the
push did not act on the file, and nothing appears in the interface. The
application log records `work items import skipped: push not authorized by an
owner`.

Importing requires those roles because it does what only they can already do. An import applies an update by deleting the local copy and rebuilding it,
and deleting issues and merge requests is an Owner's or Planner's privilege.

A successful import turns work items sync on for the project, if it was never
explicitly set either way. A project that holds copies has to publish pointers
to them and clean up after them, so it cannot sit outside the sync. A push by an
Owner or Planner therefore both brings items in and starts publishing this
project's own issue history to the branch. A project where someone deliberately
turned sync off is left alone, and nothing is imported into it.

## What an imported item looks like

An imported item looks like an ordinary issue or merge request that cannot be
changed. A banner at the top says it is a copy and links to the original.

- It keeps its number when it can. If nothing in this project uses that number,
  the copy has the same number as the original. If the number is taken, which is
  likely when the project has issues of its own, the copy gets a new one.
- Nobody here is its author. Imported items belong to the Ghost User, with a
  line in the body naming who wrote them and when. To change that, see
  [Identity matching](#identity-matching).
- Comments come across, and you cannot add more. Commenting is blocked because
  a comment added to a copy would not survive. See
  [Updates and deletions](#updates-and-deletions).
- References are rewritten to mean what they meant. A `#7` in the original
  refers to issue 7 of the other installation. Here it points at the local copy
  of that issue, under whatever number the copy has. If that issue has not been
  imported, the reference becomes a link to the original. It never resolves
  against an unrelated local item with the same number.
- Mentions do not become mentions of whoever holds that name here. They link to
  the profile on the installation the item came from, unless identity trust matched the
  person to a local account.
- Labels and milestones are created if they do not exist. They become ordinary
  labels and milestones of this project, and appear in its own `labels.yml` and
  `milestones.yml` as though you had created them.
- Confidential issues are never imported, whatever the installation the item came from chose
  to publish. See [Confidential content in work items sync](confidential_content.md).
- An item this project already has is recognized, not copied. If a document has
  the same number and the same creation time as an item here, the two are the
  same item. It is recorded as such and nothing is built. Recognition covers
  installations that began as a copy of another, such as a staging environment
  cloned from production with its database. Without it, importing would
  duplicate every shared issue into an original and a copy authored by the Ghost
  User that can never be reconciled.

  Nothing about a recognized item changes. It stays yours, stays editable, and
  is not overwritten when the other installation edits its copy. Your copy wins,
  and the two versions are not merged. If the other installation deletes its
  copy, only the record of the connection is removed.

  The creation time is what makes it the same item. Two installations that both
  have an issue 42 is ordinary, and those get separate copies.
- A merge request waits for its commits. If the commits its diff is built from
  are not in this repository, the merge request is recorded but not created, and
  it is tried again on every later run. The commits often arrive in a later
  push.

For how the imported files are laid out on the branch, see
[Work items sync file format](file_format.md).

## Updates and deletions

An update on the source is applied by rebuilding: the local copy is deleted and
made again from the new file. So nothing you add to a copy survives,
and commenting is blocked.

Deleting an item on the source deletes the copy here. Making an item
confidential on the source also deletes the copy here.

Usually each push brings its own changes in. A nightly job also re-runs the
import for installations this project already holds copies of. It catches
anything a failed or interrupted run missed, and picks up merge requests whose
commits have arrived in the meantime. It never imports from an installation this project
has not imported from before, because that would bypass the role check
on a push. Like every run, it imports only from installations that `sync.yml`
names.

For when the job runs, which is 02:15 by default, see
[Work items sync administration](../../../administration/work_items_sync.md).

## Identity matching

An imported item is attributed to a local account when the person can be matched
here. When they cannot, the item is attributed to the Ghost User with a byline
naming them. How hard to look is one setting with three levels:

| Level      | Matches on |
|------------|------------|
| `none`     | Nobody. Everyone becomes the [default user](#default-user). |
| `email`    | A published public email address. The default. |
| `username` | A published public email address, and failing that, a matching username. |

A published address is a real signal. Both installations only let someone
publish an address they have confirmed, so a match means the two accounts proved
the same mailbox. So `email` is the default.

A username match is a matching string and nothing more. Names can be released
and taken by someone else, and the match does not care whether the local account
is a person, a bot, or an administrator. So it is a separate level.

Do not read `username` as a rare tiebreaker. `ids.yml` records a public email
only for people who chose to publish one. For everyone else, the username is the
only attempt, so at that level expect it to be the usual path.

`ids.yml` is written by whoever pushes the branch. At any level above `none`, an
Owner or Planner can put a published address in it and have imported content
attributed to whoever holds that address here. They do not otherwise have that
capability. Set the level to `none` to decline it.

Changing the level is not retroactive. Items already imported keep their
attribution until the next time their source file changes and they are rebuilt.

To set the level, add `user_mapping` to the relationship in `sync.yml`, then
push the branch. Each relationship has its own level, so an installation that
knows the people of one peer and none of another can say so. This excerpt of
`sync.yml` sets the level for one relationship:

```yaml
prod:
  uuid: 2222-...
  sync:
    staging:
      import: all
      user_mapping: username
```

## Default user

Everyone the matching could not place becomes the Ghost User, unless the
relationship names another account with `default_user`. To set it, add
`default_user` to the relationship in `sync.yml`, then push the branch:

```yaml
      default_user: import-bot
```

The named account becomes the author and the assignee of whatever the peer
attributed to people who have no account here. It should usually be a service or
bot account rather than a colleague. The byline is unaffected: an item still
says who wrote it.

The named account must meet these rules:

- It must be a member of this project, through the project, a group, or an
  invited group, or be an administrator. Bots qualify, including the bot user of
  a project access token.
- Until the account exists and qualifies, nothing is imported from that peer.
  The import waits instead of falling back to the Ghost User, and continues by
  itself after the account is created or added. The only signal is the application log,
  which shows `work items import waiting: default_user cannot be used`. If an
  import does not start, check that the account exists and is a member of the
  project, and ask an administrator to check the log. See
  [Work items sync administration](../../../administration/work_items_sync.md).

For anything long-lived, use a service account instead of the bot user of an access
token. A token's bot is deleted with the token, and everything it authored is
attributed to the Ghost User.

`<ghost>` is a value of `default_user` and nothing else. It names the Ghost User
explicitly, and means the same as leaving `default_user` out.

## What importing does not protect

- Skipping confidential items is not a confidentiality boundary: anyone who can
  read this repository can still read them with `git show`. See
  [Confidential content in work items sync](confidential_content.md).
- Branches carry the directories of other installations onward. Fetching a
  branch brings every installation's directory in it, and pushing that branch on
  carries them further. An Owner or Planner who pushes a branch they fetched
  from somewhere else might be importing from an installation they have never
  heard of. Those items are imported first-hand from that installation's own
  directory, with its own identities and links, but nobody vouched for them
  beyond the person who pushed.
- Copies are only as current as the last push. There is no polling and no
  connection between installations. If the chain of pushes stops, the copies
  here stay as they are, and nothing indicates how old they are.
