# Running Unfurl Cloud tests

Unfurl Cloud specific tests fall into these groups:

- `oc/spec/`: RSpec tests, run with the root GitLab bundle.
- `oc/spec/frontend/`: JavaScript unit tests, run by Jest with the root
  GitLab JavaScript dependencies.

The end-to-end suite (`qa/qa/specs/features/oc/`) and the `:onecommons`-tagged
examples under the root `spec/` tree return with the features they cover;
this port does not have them yet.

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

Request specs that render a full page (the settings section in
`oc/spec/requests/projects/`) need the asset manifest, which the GDK's
`config/gitlab.yml` fetches from the rspack dev server. Have `gdk start
rspack` running and set `ENABLE_RSPACK=true`, or Rails asks the server for
webpack's manifest name and fails with `Could not load manifest`:

```bash
ENABLE_RSPACK=true bundle exec rspec oc/spec/requests
```

In CI, `oc/spec` runs in the `rspec-oc unit pg17` and `rspec-oc integration
pg17` jobs.

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

## Jest

Jest discovers `oc/spec/frontend/**/*_spec.js` automatically
(`jest.config.base.js`). Run every OC frontend test:

```bash
yarn jest oc/spec/frontend
```

In CI these run in the existing `jest` job; there is no separate OC Jest job.
