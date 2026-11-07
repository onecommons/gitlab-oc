---
title: Transfer work items to another installation
---

Transfer issues from one Unfurl Cloud installation to another to make them real
and editable on the receiving installation. The giving installation keeps a
read-only copy that follows the item from then on. For example, use a transfer
to retire a staging installation into a production one.

## Transfer issues

Declare the transfer in the project's `sync.yml`, then push the branch in a
specific order. Nothing is negotiated between installations and neither waits
for the other. Each acts on its own copy of the branch when a push arrives.

Push to the giving installation first. The freeze does not wait for the
receiving installation to take the items, because the gap between the two
pushes can be days. An edit made on the giver in that gap would be silently
overwritten later. Edits made on the giver after the declaration was written
but before it arrives are superseded by whatever the new owner publishes.

Until the final fetch-and-push-back step is complete, the giver's items stay
frozen. This is safe and can last indefinitely, but nothing else can be done
with them in the meantime.

Prerequisites:

- On the giving installation, work items sync must be turned on for the
  project. Nothing is published while it is off, so nothing is frozen or
  imported.
- On the receiving installation, work items sync must not have been
  deliberately turned off for the project. An import turns it on.
- The Owner or Planner role for the project on each installation. Only a push
  by one of these roles starts a transfer. See
  [Import work items from another installation](import.md).

To transfer issues:

1. Find the UUID of each installation. In each installation, go to the
   project's **Settings** > **General** > **Work items sync**. The UUID is shown as
   **This installation's ID, for sync.yml**. It is also the name of the
   installation's directory on the `work-items-sync` branch.

1. Fetch the giver's `work-items-sync` branch and check it out. In `sync.yml`,
   add `transfer` under the block of the installation giving the items away.
   Add `import: transferred` under the block of the installation receiving
   them:

   ```yaml
   ---
   _schema: sync@1

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

   The UUIDs in the example are placeholders. The names `staging` and `prod`
   are yours to choose. The block with a `transfer` entry is the giver, and the
   block with an `import` entry is the receiver.

   Paths in `transfer` are relative to the giver's own directory. The receiver
   must declare an `import` from the giver, or the push is refused. Without
   one, items would be frozen on one installation and never appear on the
   other. `import: transferred` takes only what the giver transfers, rather
   than mirroring everything the giver has. It is also what makes a transfer
   safe when one installation began as a copy of the other, for example a
   staging installation cloned from production, database included.

1. Push the branch to the giver. The giver freezes the transferred items
   immediately. They become read-only, with a banner saying where they are
   going.

   If the giver's `work-items-sync` branch has changed since you fetched it,
   fetch it again and merge it into your branch before pushing. Each
   installation writes its own directory, so only `sync.yml` can conflict. Do
   not force push: see
   [Import work items from another installation](import.md).

1. Push the branch to the receiver. The receiver imports the items and takes
   ownership of them. They become editable there, and the receiver's next sync
   publishes them as full documents rather than pointers.

   Fetch the receiver's `work-items-sync` branch if it has one, merge it into
   your branch, and push normally. Do not force push.

1. Wait for the receiver to publish the transferred issues. This is about 10
   seconds after the import by default. It is done when the receiver's files
   for those issues on its branch are full `issues@1` documents rather than
   `issue_reference@1` pointers.

   Then fetch the receiver's `work-items-sync` branch, merge it into the
   giver's branch, and push it to the giver. The giver sees its own items
   published by their new owner and replaces each frozen original with an
   ordinary copy of the new document. The copy keeps the original's number, so
   every link to `.../issues/42` still resolves.

For the full list of `sync.yml` keys, see
[Work items sync configuration file](sync_yml.md).

## Transfer limits

The following are deliberately not possible:

- A transfer cannot be undone. Deleting the declaration afterward does nothing,
  and neither does declaring the reverse. An installation never gives back an
  item it was given, and never re-freezes one it has taken. The only exits are
  completing the transfer or an administrator intervening.
- Merge requests cannot be transferred. Naming one is a rejected push, and
  `transfer: all` covers issues only.
- Confidential issues cannot be transferred, because they were never published
  for the other side to take. Both sides refuse them, so neither waits on the
  other. See [Confidential content in work items sync](confidential_content.md).
- An item cannot be promised to two installations. This is a rejected push
  rather than something resolved by precedence.

## Transfer side effects

- A satisfied `transfer` declaration is safe to leave in the file. However,
  `transfer: all` keeps transferring issues filed after the declaration lands,
  on the runs that follow. That makes it usable for emptying an installation,
  and a surprise if you leave it in the file. Delete it when the migration is
  done.
- Other installations see the item move. An installation that mirrors both
  sides watches the item disappear from one directory and reappear in the
  other, then rebuilds its copy under a new local number. Links on that third
  installation re-resolve on the next run.
