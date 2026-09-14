# Running Unfurl Cloud tests

Unfurl Cloud specific tests fall into these groups:

- `oc/spec/`: RSpec tests, run with the root GitLab bundle.
- `oc/spec/frontend/`: JavaScript unit tests, run by Jest with the root
  GitLab JavaScript dependencies.
- `qa/qa/specs/features/oc/`: end-to-end tests against a running instance,
  run with the separate `qa/` bundle.

The `:onecommons`-tagged examples under the root `spec/` tree return with the
features they cover; this port does not have them yet.

## RSpec

Run every command from the GitLab checkout.

1. Install the root bundle once (and again after changing `Gemfile.lock`):

   ```bash
   bundle install
   ```

1. Start the GDK's PostgreSQL and Redis, and create the test databases the
   first time:

   ```bash
   gdk start postgresql redis
   RAILS_ENV=test bin/rake db:create db:schema:load
   ```

1. Put Go 1.25 or later on `PATH` ahead of any Homebrew Go. The suite builds
   Gitaly into `tmp/tests/gitaly` in `before(:suite)`, and Gitaly's `go.mod`
   requires 1.25. With mise, for example:

   ```bash
   export PATH="$(mise where go@1.26)/bin:$PATH"
   ```

   A build with an older Go fails and leaves partial artifacts that later runs
   mistake for a finished build. Recover with:

   ```bash
   make -C tmp/tests/gitaly all WITH_BUNDLED_GIT=YesPlease
   ```

Then:

```bash
bundle exec rspec oc/spec
```

Specs that `require 'fast_spec_helper'` (such as
`oc/spec/lib/gitlab_edition_spec.rb`) need neither the database nor Gitaly,
but cannot share an rspec invocation with `spec_helper` specs — run the two
groups separately.

Request specs that render a full page (those under
`oc/spec/requests/projects/`) need the asset manifest, which the GDK's
`config/gitlab.yml` fetches from the rspack dev server. Have `gdk start
rspack` running and set `ENABLE_RSPACK=true`, or Rails asks the server for
webpack's manifest name and fails with `Could not load manifest`:

```bash
ENABLE_RSPACK=true bundle exec rspec oc/spec/requests
```

In CI, `oc/spec` runs in the `rspec-oc unit pg17`, `rspec-oc integration pg17`
and `rspec-oc migration pg17` jobs. The job name picks the folders:
`scripts/rspec_helpers.sh` reads the `-oc` suffix for the tree and the second
word for the level, and `tooling/quality/test_level.rb` maps that level to
folder names. `migrations` is a level of its own, so a spec under
`oc/spec/migrations` runs in none of the other two — its job was added with the
first fork migration spec.

## Specs that can reach a real Unfurl server

`oc/spec/requests/projects/invalidate_cache_spec.rb` normally stubs the HTTP
call, which proves the request the fork builds but not that a server accepts
it. Point it at a running one for the other half:

```bash
OC_TEST_UNFURL_SERVER_URL=http://localhost:8081 \
  bundle exec rspec oc/spec/requests/projects/invalidate_cache_spec.rb
```

Unset, that example is not collected, so neither CI nor an ordinary run
depends on the server being up.

**Watch for this trap in any spec reading `Gitlab.config.extra`.** The GDK's
`config/gitlab.yml` sets `extra.unfurl_server_url` under `production: &base`,
and the test environment inherits the anchor — so a spec that does not
`stub_config(extra: {})` really will POST to `localhost:8081` and behave
differently depending on whether you happen to have `unfurl serve` running.
That is what made this spec fail intermittently before it was isolated.

## Regenerating the work item snapshots

`oc/spec/fixtures/work_items/*.yml` record, byte for byte, what the work items
sync commits to the `gitlab-work-items` branch, one file per relation. They
double as documentation of the format: the placeholders carry inline `# e.g.`
comments, which `WorkItemSnapshots#strip_example_comments` removes before the
comparison. `oc/spec/services/oc/work_items/record_serializer_snapshot_spec.rb`
verifies them and doubles as their generator.

A failure there means the serializer's output changed. If that was deliberate
(a GitLab upgrade touching `lib/gitlab/import_export/project/import_export.yml`,
or an intentional change to `OC::WorkItems::RecordSerializer`) regenerate them
and review the diff. A change to the file layout itself also needs
`RecordSerializer::SCHEMA_VERSION` bumped, which the `_schema` header at the
top of every snapshot will show:

```bash
REGENERATE_WORK_ITEM_SNAPSHOTS=1 \
  bin/rspec oc/spec/services/oc/work_items/record_serializer_snapshot_spec.rb
```

The run writes the snapshots and then verifies what it wrote. The setup shared
by both modes lives in `oc/spec/support/helpers/work_item_snapshots.rb`; edit
the Markdown or the records there rather than the YAML by hand. The snapshots
are interpolated with `format()`, so a literal `%` must be written `%%`.

## QA tests

The end-to-end tests under `qa/qa/specs/features/oc/` use the separate `qa/`
bundle against a running GitLab instance. There are three: work items sync,
and two for GitHub pull mirroring (see [GitHub pull mirroring](#github-pull-mirroring)
below, which needs a GitHub account of your own).

The work items sync one drives a real `git push` and reads back what Git printed, which
is the only place three things can be checked at all: that a rejected
`sync.yml` reaches the pusher with Gitaly's `GitLab:` prefix on it, that an
accepted one prints its summary, and that the worker chain (push →
`PostReceive` → `ImportWorker` → `SyncWorker`) runs through on its own.

1. Start GDK, with Sidekiq: every step in the suite is asynchronous.

1. Install the QA bundle once (from the GitLab checkout):

   ```bash
   (cd qa && bundle install)
   ```

1. Give the suite an admin API token; it creates the QA sandbox group and
   user. A GDK needs nothing here: its seed data gives `root` a token named
   `seeded-api-token` whose value is the framework's built-in default, and
   the suite uses it when `GITLAB_QA_ADMIN_ACCESS_TOKEN` is unset. Against
   any other instance, set that variable to a temporary admin personal
   access token with the `api` scope, created while signed in as an
   administrator at `/-/user_settings/personal_access_tokens` (**Add new
   token**). Do not put it in a file, shell history, or committed
   configuration, and revoke it there when finished. Without either, the
   suite falls back to creating a token through a browser, which needs
   ChromeDriver.

Then:

```bash
cd qa
QA_GITLAB_URL=http://gdk.test:3000 \
bundle exec rspec qa/specs/features/oc/api/3_create/work_items_sync_spec.rb
```

The peer installation is synthetic: its directory is a handful of files
committed by the test. That is what a peer is — an instance directory is
exactly the files somebody committed under it, and reading one never involves
the installation that wrote it. The writing side is covered from this end by
the first example, which asserts that this project's own issues reach the
branch.

Most of the wait is one thing: a sync is enqueued ten seconds out, so that
somebody editing an issue three times in a row produces one commit rather than
three, and that delay lands on the critical path eight times in the suite. It
can be shortened with `OC_WORK_ITEMS_SYNC_DELAY`, in seconds. The delay is
applied by whichever process *enqueues* the sync, and that is both Rails and
Sidekiq, so set it for the whole GDK by adding a line to `env.runit` at the
GDK root (every service sources it) and restarting the two that matter:

```bash
echo 'export OC_WORK_ITEMS_SYNC_DELAY=1' >> ../env.runit
gdk restart rails-web rails-background-jobs
```

Anything that is not a number of seconds at least zero is ignored in favour
of the ten-second default, so a typo makes the suite slow rather than
silently turning the coalescing off. Put it back when you are done: with no
delay at all, nothing about the coalescing behaviour is being exercised.

### GitHub pull mirroring

`qa/specs/features/oc/api/1_manage/import/github_mirroring_opt_out_spec.rb` and
`qa/specs/features/oc/browser_ui/1_manage/import/github_pull_mirroring_spec.rb`
import a real repository from a real GitHub account, so they need one:

- `QA_GITHUB_ACCESS_TOKEN` — a GitHub personal access token with `repo` scope
  (classic; fine-grained tokens are not supported by the importer). Create it
  yourself at <https://github.com/settings/tokens>, pass it in the environment
  of the run, and revoke it afterwards. Do not put it in a file, shell history,
  or committed configuration.
- `QA_GITHUB_IMPORT_REPOSITORY` — optional. Defaults to the fork's fixture,
  `aszs/gitlab-qa-import-fixture`; set it to `owner/name` of any other
  repository the token can read and create webhooks on. (Upstream's own
  default, `gitlab-qa-github/import-test`, belongs to GitLab's QA account and
  cannot be used here.)

Export the token in the shell you run from — `read -rs QA_GITHUB_ACCESS_TOKEN
&& export QA_GITHUB_ACCESS_TOKEN` keeps it out of shell history — and revoke it
when you are done:

```bash
cd qa
QA_GITLAB_URL=http://gdk.test:3000 \
bundle exec rspec qa/specs/features/oc/api/1_manage/import/github_mirroring_opt_out_spec.rb
```

The browser one additionally needs ChromeDriver, and it exercises the fork's
repository-settings section end to end: the checkbox off and on again, and the
**Fetch Latest** button.

Both pass (2026-09-13). Four things the first live run needed, all of which
will bite again on a fresh machine:

- A stale `/usr/local/bin/chromedriver` (Homebrew cask, 2022) shadows Selenium
  Manager, which only downloads a matching driver when `PATH` has none. Symptom
  is `session not created: This version of ChromeDriver only supports Chrome
  version 104`. Remove it: `brew uninstall --cask chromedriver`.
- `ApplicationSetting.current` must be valid, or `ImportSource.enable('github')`
  fails with a 400 naming `rate_limits`/`importers`/`default_profile_preferences`
  and no spec can start. This GDK's database was migrated by a newer checkout
  than the branch, leaving settings keys the 19.3 schemas reject; see the
  toolchain notes.
- The token can come from the GitHub CLI -- `QA_GITHUB_ACCESS_TOKEN="$(gh auth
  token)"` -- which avoids creating and revoking a PAT by hand. It needs `repo`
  scope, which covers repository webhooks.
- The browser spec creates a real webhook on the fixture repo per run, pointing
  at `gdk.test:3000`, which GitHub cannot reach. They accumulate, and GitHub
  caps a repository at 20. Prune them occasionally.

There is no CI job for the QA suite in this port yet.

## Jest

Jest discovers `oc/spec/frontend/**/*_spec.js` automatically
(`jest.config.base.js`). Run every OC frontend test:

```bash
yarn jest oc/spec/frontend
```

In CI these run in the existing `jest` job; there is no separate OC Jest job.
