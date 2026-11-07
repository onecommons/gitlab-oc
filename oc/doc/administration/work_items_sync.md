---
title: Work items sync administration
---

[Work items sync](../user/project/work_items_sync.md) runs two scheduled jobs
that keep the sync branch of each project with sync turned on correct, and
exposes a worker and an API endpoint for forcing or toggling sync.

## Nightly job

The nightly job runs at 02:15 by default. It re-syncs every project with sync on
that might have drifted, and removes files for items that no longer exist.
Projects with nothing newer than their last sync are skipped.

For the other projects, the job usually looks only at issues and merge requests
that changed since the last sync. The cost of a busy project is therefore
proportional to its daily activity, not to its size.

The job rebuilds everything instead when:

- A label, a milestone, or the project itself changed. The job copies each of
  these into every file that references it.
- The branch has no record of how far the last run got.

Label and milestone edits, and project changes such as renaming or changing
visibility, are picked up by this job rather than immediately.

The job also re-runs [imports](../user/project/work_items_sync/import.md) for
installations the project already holds copies of. This catches anything a
failed or interrupted run missed, and picks up merge requests whose commits
have arrived since the last run. The job:

- Never imports from an installation the project has not imported from before,
  so it cannot bypass the role check on a push.
- Imports only from installations that the project's
  [`sync.yml`](../user/project/work_items_sync/sync_yml.md) names.

## Weekly job

The weekly job runs on Sunday at 03:15, at the lowest priority. It rebuilds a
project completely, ignoring timestamps.

A few changes move no timestamp the nightly job can see, such as a deleted
comment or an added or removed reaction. If the immediate sync for one of these
fails, the weekly job corrects it.

The job runs for a project once after each period of activity, not every week.
A project that nobody has touched in a year is left alone.

## Job efficiency

Both jobs decide whether a project needs attention before they read anything
from its repository, so a dormant project costs a few database queries. Neither
job commits a file whose contents have not changed.

## Sync delay

Sync runs about 10 seconds after a change. Set the `OC_WORK_ITEMS_SYNC_DELAY`
environment variable to change the delay, in seconds. Invalid or negative
values fall back to 10.

## Force a full resync

Force a full resync of a project when you don't want to wait for the next
scheduled run.

Prerequisites:

- Administrator access.
- Access to the Rails console.

To force a full resync:

1. Start a Rails console session.
1. Run the worker with the project ID. `project_id` is the ID of the project,
   shown on the project overview page:

   ```ruby
   OC::WorkItems::FullSyncWorker.perform_async(project_id)
   ```

The worker rewrites the sync branch shortly after. To check, look at the
latest commit on the branch.

## Force a purge and rebuild

Force a purge and rebuild when a project's visibility changed outside the
project update service, for example directly in the database or from a console.
The update service triggers the rebuild automatically, so changes made any other
way do not. For more information, see
[Confidential content in work items sync](../user/project/work_items_sync/confidential_content.md).

Prerequisites:

- Administrator access.
- Access to the Rails console.

To force a purge and rebuild:

1. Start a Rails console session.
1. Run the worker with `true` as the second argument. This replaces the
   project's own history on the sync branch before rebuilding it.
   `project_id` is the ID of the project, shown on the project overview page:

   ```ruby
   OC::WorkItems::FullSyncWorker.perform_async(project_id, true)
   ```

The worker rebuilds the sync branch shortly after. To check, look at the
latest commit on the branch.

## Work items sync API

Use the API to turn work items sync on or off for a project:

```plaintext
POST /api/v4/projects/:id/work_items_sync?enabled=true
```

The caller must be able to administer the project. When sync is on after the
request, the endpoint queues a full sync of the project.

| Attribute           | Type    | Required | Description |
|:--------------------|:--------|:---------|:------------|
| `id`                | integer or string | Yes | ID or URL-encoded path of the project. |
| `enabled`           | boolean | Yes      | Whether to sync work items. |
| `sync_confidential` | boolean | No       | Also sync confidential issues and internal notes. Private projects only. If omitted, the current setting is kept. Projects start with it off. |

If the request sets `sync_confidential` to `false` for a project that was
syncing confidential content, the endpoint purges that content from the sync
branch history. A request that leaves out `sync_confidential` keeps the current
setting and purges nothing.

A successful request returns `200` and these fields:

- `work_items_sync_opted_in`
- `work_items_sync_enabled`
- `work_items_sync_confidential`

## Log messages

Some events are recorded only in the application log.

| Event | What to look for |
|:------|:-----------------|
| An import was skipped because the person pushing is not an Owner or Planner of the project. The push still succeeds and nothing appears in the interface. | `work items import skipped: push not authorized by an owner` |
| An import is waiting because the `default_user` in `sync.yml` does not exist or does not qualify. Nothing is imported from that peer, and the import continues by itself after the account exists or is added. It does not fall back to the Ghost User. | `work items import waiting: default_user cannot be used` |
| A draft was not created. The reason follows the key, and the draft stays on the branch. | `work item drafts skipped: <key>: <reason>` |
| Drafts were not created because work items sync is off for the project. They are created by the first push after sync is turned on. | `work item drafts skipped: work items sync is off` |
| A waiting draft was dropped when the branch was rebuilt after syncing confidential content stopped, because it was confidential or could not be read. | `work item drafts dropped by purge: <key>` |
