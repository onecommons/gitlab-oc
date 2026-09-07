# Working in the Unfurl Cloud fork of GitLab

This is a fork of GitLab 19.3 running as the **`oc` (OneCommons) edition**:
`Gitlab.oc?` is true and EE code never loads. Fork-local code lives under
`oc/` — read [Where code goes](#where-code-goes) before adding any.

`GitlabEdition.oc?` is true when `oc/` exists and `GITLAB_ONLY` is unset, and
`ee?` is then always false. `config/helpers/is_oc_env.js` mirrors it for the
build tools, which expose it as `IS_OC`. Set `GITLAB_ONLY=1` to boot stock
GitLab from the same checkout — to compare behaviour, or to regenerate a file
that upstream generates in EE mode.

## Toolchain

The GDK in the parent directory uses mise (`gdk.yml` sets `asdf: opt_out:
true`), so `mise activate` or `mise exec` provide the tools. Versions come
from this repository's `.tool-versions` and `.ruby-version` (Ruby 3.3.11, Node
22, Yarn 1) and the GDK's own `.tool-versions` (Postgres 17). If another
version manager is also installed and its shims win, put mise's Ruby first
explicitly:

```bash
export PATH="$HOME/.local/share/mise/installs/ruby/3.3.11/bin:$PATH"
```

Run `bundle install` once. Lefthook's pre-commit hook runs RuboCop through
the bundle, so `git commit` fails without it.

Gitaly's `go.mod` requires Go 1.25 or later; the GDK pins 1.26 in its
`.tool-versions`. A Homebrew Go 1.24 earlier on `PATH` makes the RSpec
suite's Gitaly build fail — see `oc/spec/README.md`.

### Unfurl server integration

To make a development instance talk to a local Unfurl Server, add this to the
`server` block of `$GDK_ROOT/nginx/conf/nginx.conf`:

```nginx
 location /services/unfurl-server {
      proxy_pass http://localhost:8081/;
  }
```

(or patch the GDK's `components/nginx/nginx.conf.erb` so the change survives
`gdk reconfigure`).

## Development

### Where code goes

- OneCommons code lives under `oc/`, mirroring the upstream tree
  (`oc/app/services/oc/...`, `oc/lib/oc/...`, `oc/app/workers/oc/...`).
  `config/application.rb` registers `oc/` the way it registers `ee/` and
  `jh/`: autoload paths, `oc/config/initializers`, `oc/config/routes`,
  `oc/spec/factories` and `oc/app/assets`.
- Extend upstream classes with a prepended `OC::` module rather than editing
  them. Most upstream classes already end with `prepend_mod_with '...'`, which
  picks up the matching module under `oc/` automatically.
- Routes: `oc/config/routes` is first in `config.paths["config/routes"]`. A
  name upstream draws with `draw_all` (`project`, `group`, `api`,
  `dashboard`, ...) is drawn from every path, so `oc/config/routes/<name>.rb`
  extends CE's file with no upstream edit. A name drawn with plain `draw` is
  first match only — an oc file of that name would *replace* CE's, silently.
  For those, use a new name and add its `draw` call under `# OC Change`.
- Frontend code resolves through the aliases in `config/helpers/aliases.js`
  (`oc`, `oc_component`, `oc_else_ce`, `oc_images`, `oc_icons`,
  `oc_empty_states`, `oc_pages`, `oc_dashboard`, `oc_vue_shared`, `oc_jest`),
  which webpack, Vite, Rspack, Jest and ESLint all share. `oc_else_ce/x`
  resolves to `oc/` in the oc edition and to CE otherwise, so the file must
  exist in both. A page entry under `oc/app/assets/javascripts/pages/`
  replaces the CE entry at the same path.
- When an in-place upstream edit is unavoidable, mark it with an `# OC Change`
  comment (in HAML, `-# OC Change`). Keep it to as few lines as possible —
  ideally a single `render` or `prepend_mod` call. These markers are how the
  fork is rebased onto new GitLab releases — grep for them to find every
  divergence from upstream.
- **AVOID VERBOSE COMMENTS THAT EXPLAIN THE OBVIOUS.** The code says what it
  does; comment only what it cannot — a non-obvious constraint, a reason a
  guard exists. `# OC Change` on its own is the whole comment unless something
  is genuinely surprising. This applies to commit messages too: say what
  changed and why it was needed, once.
- Commit subjects take an `oc:` prefix and [Conventional
  Commits](https://www.conventionalcommits.org/en/v1.0.0/) form —
  `oc: <type>(<optional scope>): <Description>` — where type is one of `feat`,
  `fix`, `docs`, `refactor`, `build`, `ci`, `test`, `chore`. Upstream's rules
  still apply (`doc/development/contributing/merge_request_workflow.md`, and
  the post-commit hook lints them); they permit a lowercase `prefix:` as long
  as the description is capitalised. Upstream's `.ai/git.md` forbids
  `Co-Authored-By:` trailers; this fork keeps them.

### Gotchas

- **Inside `module OC`, write `::Gitlab::...`.** A bare `Gitlab::` resolves to
  `OC::Gitlab`, which exists because of `oc/lib/oc/gitlab/sidekiq_config.rb`.
  The failure looks like `uninitialized constant OC::Gitlab::Json`.
- **The `oc/` path determines the constant, so extensions need an `oc/`
  segment.** Zeitwerk treats `oc/app/<layer>` as an autoload root, so
  `oc/app/helpers/oc/nav_helper.rb` defines `OC::NavHelper` (which
  `NavHelper.prepend_mod_with` then prepends), while
  `oc/app/helpers/nav/top_nav_helper.rb` defines plain `Nav::TopNavHelper` —
  the *same* constant as upstream. CE paths are registered first, so a file
  like that is silently shadowed: never loaded, no error, no effect. If an
  override seems to do nothing, check the path before debugging the code.
- **The first namespace after `OC::` must be a bounded context.** The
  `Gitlab/BoundedContexts` cop strips a leading `OC::` and requires the next
  module to be listed in `config/bounded_contexts.yml`, an upstream file. Put
  new code under an existing context where one fits; a fork-only namespace
  needs an entry there, and that entry is a rebase conflict every release.
- **New or renamed Sidekiq workers** require regenerating
  `oc/app/workers/all_queues.yml`, or CI fails:

  ```bash
  RAILS_ENV=test bin/rake gitlab:sidekiq:all_queues_yml:generate
  ```

  Leave `config/sidekiq_queues.yml` alone: upstream generates it in EE mode
  and checks it only there (`EEOnlyTask` in `scripts/static-analysis`), and
  regenerating it as `oc` strips every EE queue. A worker's `feature_category`
  must be one of the values in `config/feature_categories.yml`, and a worker
  that sets a non-default `sidekiq_options retry:` needs an entry in the
  `retry_exceptions` hash in `spec/workers/every_sidekiq_worker_spec.rb`.
  Cron schedules go in `oc/config/schedule.yml`, loaded beside
  `config/schedule.yml`.
- **`oc/rubocop/rubocop-oc.yml` is generated.** It gives every `ee/` and `jh/`
  Include/Exclude entry in `.rubocop.yml` and `rubocop/*.yml` an `oc/` twin.
  Rerun `ruby oc/support/generate_rubocop_config.rb` after an upstream bump;
  never edit the file by hand. `.rubocop.yml` inherits every YAML file under
  `oc/rubocop/`, so hand-written oc-only config belongs in a separate file
  there.
- **RSpec `feature_category` metadata** is required on every top-level
  `describe` and must be a `config/feature_categories.yml` value, or one of
  `tooling`, `test_platform` and `rails_platform` (`rubocop/feature_categories.rb`)
  for specs of the fork's own plumbing.
- **Long command output gets truncated** by the `rtk` CLI wrapper, which
  swallows most rspec and `grep` stdout. Redirect to a file in the scratchpad
  directory and read the file instead of relying on the terminal output.

### Migrations and new tables

Fork-owned tables take an `oc_` prefix, which cannot collide with anything
upstream adds later. What is not obvious about them:

- **The migration class name uses the `OC` acronym inflection**
  (`config/initializers_before_autoloader/000_inflections.rb`), so
  `oc_replicated_work_items` camelizes to `CreateOCReplicatedWorkItems`. Rails
  will not find `...Oc...`.
- **Migrations are `Gitlab::Database::Migration[2.3]`** and declare
  `milestone '<major>.<minor>'` matching `VERSION`, like the newest files in
  `db/migrate/`.
- **`db/docs/oc_*.yml` needs `table_name`, `feature_categories`,
  `gitlab_schema` and `milestone`** (`spec/db/docs_spec.rb`). Leave
  `introduced_by_url` blank: upstream's semantic is "the GitLab.com merge
  request that added this table", which does not exist for us, and it is not
  a required field.
- **`gitlab_schema` is `gitlab_main_org`** for anything that belongs to a
  project, group or organization (`gitlab_main` is deprecated), and that
  schema requires a `sharding_key` — a foreign-keyed column pointing at
  `projects`, `namespaces` or `organizations`, written as
  `sharding_key: { project_id: projects }`. The schemas and what may
  reference what are defined in `db/gitlab_schemas/*.yaml` and explained in
  `doc/development/cells/_index.md`.
- **Avoid a `jsonb` column** unless you also want a `JsonSchemaValidator` on
  the model or an entry in `ignored_jsonb_columns_map` in
  `spec/db/schema_spec.rb` — an upstream file, so an entry there is a rebase
  conflict every release. A `text` column holding JSON avoids both, and
  nothing queries inside these values anyway. For the same reason prefer real
  foreign keys over a polymorphic pair: every column ending in `_id` needs one
  or an entry in that file's `ignored_fk_columns_map`.
- **Check `git status` after `bin/rake db:migrate`.** It can rewrap
  `description:` lines in unrelated `db/docs/*.yml` files, and its
  `structure.sql` dump can differ from the committed one for reasons that have
  nothing to do with your migration. Revert those, and keep only your own
  table's lines in `structure.sql`.

### Linting

Run RuboCop on every file you add or change before considering work done —
`oc/` is linted like the rest of the tree, and CI enforces it:

```bash
bundle exec rubocop path/to/file.rb path/to/other.rb
```

Existing files may already have offenses. Check against `git stash` before
assuming an offense is yours.

### Tests

**Consult `oc/spec/README.md`** for prerequisites and commands — notably that
`oc/spec` builds its own Gitaly and needs Go 1.25 or later on `PATH`.

Where tests belong:

- `oc/spec/**` — RSpec for `oc/` code, mirroring the source layout. Runs in
  the `rspec-oc unit pg17` / `rspec-oc integration pg17` CI jobs, which select
  the folder from the `-oc` suffix in the job name (`scripts/rspec_helpers.sh`).
- `oc/spec/frontend/**` — Jest, discovered automatically
  (`jest.config.base.js`); runs in the existing `jest` CI job.
- Root `spec/**` — only when OneCommons behavior needs coverage beside the
  upstream implementation. Tag those examples `:onecommons`. The job that ran
  them in the 15.11 fork (`rspec-oc upstream specs`, an explicit file list in
  `.gitlab/ci/rails.gitlab-ci.yml` mirrored in `oc/spec/README.md`) has not
  been re-created in this port; add it with the first such file. Edits to an
  *untagged* upstream example (for instance adding an `# OC Change` entry to
  an existing expectation) need no list entry — the normal FOSS RSpec shards
  already run that file.
- `qa/qa/specs/features/oc/**` — end-to-end, separate `qa/` bundle. Not yet
  ported.
