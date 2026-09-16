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
22) and the GDK's own `.tool-versions` (Postgres 17). If another
version manager is also installed and its shims win, put mise's Ruby first
explicitly:

```bash
export PATH="$HOME/.local/share/mise/installs/ruby/3.3.11/bin:$PATH"
```

Run `bundle install` once. Lefthook's pre-commit hook runs RuboCop through
the bundle, so `git commit` fails without it.

Gitaly's `go.mod` requires Go 1.25 or later; the GDK pins 1.26 in its
`.tool-versions`. A Homebrew Go 1.24 earlier on `PATH` makes the RSpec
suite's Gitaly build fail — see `oc/spec/README.md`. The same applies to
`pg_dump`, which `db:migrate` runs and which must match the server's major
version (mise's `postgres` install has one).

### Yarn and the oc-pages package

Most of the fork's Vue code is the `oc-pages` package in the
[unfurl-gui](https://github.com/onecommons/unfurl-gui) monorepo, pulled in as
a Git dependency: `"oc-pages": "https://github.com/onecommons/unfurl-gui#head=vue3&workspace=oc-pages"`
in `package.json`, with `yarn.lock` pinning the commit. The `workspace=`
selector is a Yarn Berry feature, so the fork pins **Yarn 3.8.7** — the same
release unfurl-gui uses — through `yarnPath` in `.yarnrc.yml` and the vendored
`.yarn/releases/yarn-3.8.7.cjs`. Upstream's Yarn 1 on `PATH` delegates to it,
so nothing needs installing; `yarn --version` must print 3.8.7 in this tree.
Consequences:

- **The lockfile is regenerated, not merged, at each upstream upgrade**: take
  upstream's `yarn.lock` and run `yarn install`, which imports it.
- Berry runs the root package's lifecycle scripts *after* linking and does not
  run `pre*`/`post*` hooks of ordinary scripts. Upstream's `preinstall` (which
  deleted `node_modules` when Yarn 1's integrity file was missing) is removed
  and `prelint:stylelint` is folded into `lint:stylelint`. Its portable shell
  has no `${VAR:=default}`; the scripts use `${VAR:-default}`.
- `resolutions` use Berry's `parent/dep` form, not Yarn 1's `**/parent/dep`.
- `yarn install --frozen-lockfile` (upstream CI) still works;
  `--pure-lockfile`, which the GDK's `make gitlab-yarn` uses, does not — run
  `yarn install` by hand after `gdk update`.
- The build tools skip the EE-only frontend islands in this edition
  (`scripts/build_frontend_islands`).

Re-pin to the branch head with `oc/scripts/update-oc-pages.sh`, which commits
the result. The package's directories are reached through tracked symlinks
(`oc/app/assets/javascripts/{dashboard,project_overview,public_cloud,vue_shared}`
→ `node_modules/oc-pages/…`). `config/rspack.config.mjs` sets
`resolve.symlinks: false`, so rspack sees those files at the symlinked `oc/`
path rather than their resolved one under `node_modules` — one identity per
file, which is what the `oc_pages`/`oc_vue_shared` aliases and upstream's Vue 3
infection scanner are written against. `config/rspack/loader_rules.js` carves
the path out of the swc and graphql-tag exclusions (`OC_PAGES_SOURCE`, which
matches both spellings so a rule keyed to one does not quietly stop applying),
and `config/rspack/oc_pages.js` loads its bare `.svg` imports as markup.
GitLab's ESLint and Prettier ignore the four directories; the package lints
itself.

### Developing against a local unfurl-gui checkout

Point the four oc-pages source directories at your checkout:

```sh
sh oc/scripts/link-oc-pages.sh ~/_dev/unfurl-gui
gdk restart rspack
```

The script prints the undo command: a `git restore` of those four symlinks plus
`rm -f tmp/infection_scanner.json` and another restart. Nothing else changes --
`package.json` and `yarn.lock` are untouched and no `yarn install` runs, so
there is no lockfile churn to keep out of a commit.

It works because those directories are already symlinks into
`node_modules/oc-pages`, and `resolve.symlinks: false` means rspack keeps
calling the files `oc/app/assets/javascripts/...` whatever they point at, so the
aliases, the `OC_PAGES_SOURCE` loader rules and the infection scanner all keep
matching. **Dependencies still come from the pinned package**, because
dependency resolution is separate from where the source file sits. If your
working copy adds a dependency the pin lacks, re-pin instead.

`watchOptions.followSymlinks` is on for this: rspack otherwise watches the
symlink rather than its target, and edits never reach the build. If a change
still does not appear, `gdk restart rspack` picks it up.

**Do not use a `link:` resolution in `package.json`.** Yarn's `link:` protocol
maps the path but installs none of the linked package's dependencies -- unlike
`portal:` and the git pin -- so oc-pages' `@formily/*` and `vue-json-pretty` go
unresolved. `config/rspack/oc_pages.js` compensates by appending the checkout's
`node_modules` roots to `resolve.modules` after GitLab's own, but the route
still dirties `package.json` and `yarn.lock`, still needs a `yarn install`
(which crashes a running rspack: stop it, install, start it again), and buys
nothing the symlinks do not. Berry's `yarn link` is worse: it writes a
`portal:`, which the node-modules linker rejects here because the checkout's
`d3`, `marked` and `dompurify` conflict with GitLab's.

The packages that must stay single copies (`vue`, `vuex`, `vue-router`,
`vue-apollo`, `vue-demi`, `@gitlab/ui`, `@apollo/client`, `graphql-tag`,
`lodash`, `jquery`, `mitt`, `js-cookie`) are pinned to GitLab's by absolute
aliases in `config/helpers/aliases.js` either way.

### Stylesheets

`scripts/frontend/lib/compile_css.mjs` compiles SCSS into `app/assets/builds/`
(the rspack dev server keeps it running as a watcher). It gives `oc/` the same
hooks as `ee/`: `oc/app/assets/stylesheets` is first on the load path, and
`_application_base.scss` and `application_dark.scss` import `application_oc`
and `application_dark_oc`, which resolve to the no-op files under
`app/assets/stylesheets/_oc/` in a GitLab-only build and to
`oc/app/assets/stylesheets/_oc/` in the oc edition. Fork rules go in the
`onecommons*.scss` files those two entry points import; a new page bundle goes
under `oc/app/assets/stylesheets/page_bundles/`.

19.3 puts the colour mode class on `<html>`, so dark-mode rules are scoped to
`:root.gl-dark`, never `body.gl-dark`. The fork's look is carried mostly by
token overrides: the brand tint of the default navigation theme sits on
`:root.ui-neutral` (15.11 restyled `ui-indigo` the same way), dark mode forces
the near-black ground on `html, body` and colours every `h2`–`h6` (and `h1`
inside `.content`) Unfurl blue, exactly as 15.11 did. Prefer overriding a design token
(`--gl-button-confirm-primary-*`, `--gl-tab-selected-indicator-color-default`,
`--default-regular-font`) to restyling `.gl-*` classes; where a `.gl-*` rule is
unavoidable, `.stylelintrc` exempts `oc/app/assets/stylesheets` from
`gitlab/no-gl-class`, as it does upstream's own dark overrides.

The Noto Sans faces are served statically from `public/oc/assets/fonts/`; the
15.11 styles for views this port does not have yet (login, help, explore,
dashboard, error pages, mailer) travel with those views when they are ported.

### Unfurl server integration

The blueprint pages call the Unfurl server at `/services/unfurl-server`, which
production proxies (the chart's Ingress) and which a GDK without NGINX does
not have. Instead run the server with CORS for the GitLab origin and tell the
frontend where it is; `gon.unfurl_server_url` comes from the `extra` section
of `gitlab.yml`, and the origin also has to be allowed by the CSP, which is
configuration (`content_security_policy.directives.connect_src` replaces the
whole default, so include the dev servers too):

```yaml
production: &base
  gitlab:
    content_security_policy:
      directives:
        connect_src: "'self' http://localhost:* ws://localhost:* wss://localhost:* http://gdk.test:* ws://gdk.test:* wss://gdk.test:*"
  extra:
    unfurl_server_url: 'http://localhost:8081'
```

```bash
UNFURL_HOME= unfurl serve --clone-root <scratch dir> --cloud-server http://gdk.test:3000 \
  --port 8081 --cors http://gdk.test:3000
```

`UNFURL_HOME=` matters: with a home project, a repository redirect in
`~/.unfurl_home/local/unfurl.yaml` (`unfurl.cloud/onecommons/std` pointing
somewhere else, say) makes every environment that imports `std` fail to export
with `Path not allowed outside of repository or document root`, and one
unexportable environment disables environment creation for the whole dashboard.
unfurl-gui's own harness runs it the same way — see its README's
`UNFURL_DEFAULT_ENV`.

Two more things a *deployment* needs on a development instance, both found by
running the dashboard's cypress suite against a GDK:

- **`registry.enabled: true` in `config/gitlab.yml`.** `Gitlab::Auth.registry_scopes`
  returns `[]` when the registry is off, so `read_registry`/`write_registry`
  drop out of `resource_bot_scopes` and the dashboard's
  `POST /api/v4/projects/:id/access_tokens` is a 400 — which surfaces in the
  browser only as "Unable to create access token". The scopes are not gone
  from 19.3; they are conditional.
- **`onecommons/ci`**, which the seed imports. A dashboard's whole
  `.gitlab-ci.yml` is an `include:` of it.

### Instance settings

Unfurl Cloud configures its instances from a script in a separate blueprint.
The 19.3 form of it, which is also what a GDK wants:

```ruby
# rails console. Removed in 19.3, do not re-add: in_product_marketing_emails_enabled
# and suggest_pipeline_enabled are gone from ApplicationSetting -- no attribute,
# no column -- and referencing either raises before anything after it applies.
admin = User.admins.first  # not User.first: lowest id is not necessarily an admin

::ApplicationSettings::UpdateService
  .new(ApplicationSetting.current_without_cache, admin, { home_page_url: '' })
  .execute

ApplicationSetting.current_without_cache.update!(
  # identity
  help_page_documentation_base_url: '',        # serve oc/doc rather than docs.gitlab.com
  personal_access_token_prefix: 'uc-',

  # accounts
  user_default_external: true,
  require_admin_approval_after_user_signup: false,
  email_confirmation_setting: 'hard',
  invisible_captcha_enabled: true,

  # GitLab's own marketing, out of the UI
  hide_third_party_offers: true,
  whats_new_variant: 'disabled',
  help_page_hide_commercial_content: true,     # the DevSecOps pitch and promo links on /help
  version_check_enabled: false,                # the version badge only -- see below
  duo_features_enabled: false,                 # AI promotion throughout the UI
  user_deactivation_emails_enabled: false,

  # telemetry: stop reporting to version.gitlab.com
  usage_ping_enabled: false,
  usage_ping_generation_enabled: false,        # both, or the worker still runs -- see below
  include_optional_metrics_in_service_ping: false,
  gitlab_product_usage_data_enabled: false,    # jsonb accessor on service_ping_settings

  # Production has every import source its version offers, and a GDK that has
  # been narrowed to a subset renders no GitLab export button on
  # /projects/new#import_project, which the project-import e2e specs need.
  # 19.3 dropped two of production's: `gitlab` (the GitLab.com importer) and
  # `phabricator`.
  import_sources: %w[github bitbucket bitbucket_server fogbugz git gitlab_project gitea manifest],

  # limits
  max_artifacts_size: 1024,
  default_branch_protection: ::Gitlab::Access::PROTECTION_FULL
)
```

A GDK needs three instance CI variables as well, which production sets from
its own blueprint. Mark all of them **protected**: in this fork that means a
variable reaches no CI job at all, and every reader here goes through
`all_cached`, which ignores the flag — so protecting them costs nothing and
keeps them out of every tenant's pipeline.

```ruby
# rails console, continuing from above. 'cypress-e2e' is what the fork's
# cypress suite signs up with (OC_INVITE_CODE, with OC_USERNAME/OC_PASSWORD
# unset so it takes the signup path, which is the only one that creates a
# dashboard).
instance_vars = {
  'UNFURL_VALID_INVITE_CODES' => 'cypress-e2e',
  'UNFURL_APPROVE_MATCHING_CODES' => '\Acypress-e2e\z',  # single-quoted: double quotes eat the backslashes
  # Fetched by the browser as-is, so it must be absolute and must match
  # extra.unfurl_server_url -- see below.
  'UNFURL_CLOUDMAP_JSON' =>
    "#{::Gitlab.config.extra['unfurl_server_url']}" \
    '/types?auth_project=onecommons%2Fstd&cloudmap=onecommons/cloudmap&file=dummy-ensemble.yaml'
}

# with_indifferent_access is not optional: the service looks the record up with
# attributes[:id] but strips it with except('id'), because it is written for
# ActionController::Parameters. A plain Hash misses the lookup and tries to
# create a duplicate key.
attributes = instance_vars.map do |key, value|
  { id: ::Ci::InstanceVariable.find_by(key: key)&.id,
    key: key, value: value, protected: true, masked: false }.compact.with_indifferent_access
end

service = ::Ci::UpdateInstanceVariablesService.new({ variables_attributes: attributes }, admin)
raise service.errors.join(', ') unless service.execute
```

`UNFURL_VALID_INVITE_CODES` on its own looks sufficient and is not. Signup
succeeds with it and the dashboard project is created, but the user is left
active with `confirmed_at` NULL, and an unconfirmed user cannot authenticate
over git HTTP — so anything driving that account fails later, somewhere else.
`UNFURL_APPROVE_MATCHING_CODES` is what makes `skip_confirmation?` true. It is
a `Regexp.new` source string, so anchor it: unanchored, any code *containing*
the pattern is approved.

`UNFURL_CLOUDMAP_JSON` is the cloud map's only data source:
`PublicCloudController#cloudmap` and `_oc_project_overview.html.haml` read it,
the view renders it as `#chart[data-cloudmap]`, and oc-pages fetches that value
verbatim (`public_cloud/raw-data.js`). Unset, haml omits the attribute, oc-pages
falls back to the relative `/services/unfurl-server/...` path that only
production's Ingress serves, and the chart never draws. **Nothing substitutes a
placeholder in it** — not the controller, not oc-pages — so it has to be an
absolute URL naming the same server as `extra.unfurl_server_url`, which on a GDK
is the locally run Unfurl server rather than a proxy path.

Things the 15.11 version of this script got away with and 19.3 does not:

- **`default_branch_protection` is now half-vestigial.** The integer column
  survives and `Namespace#default_branch_protection` still falls back to it,
  but `default_branch_protection_defaults` (jsonb) is what actually governs.
  They can disagree: setting the integer to `PROTECTION_FULL` leaves
  `allow_force_push: true` in the jsonb untouched. If force-push behaviour is
  what you mean to set, set the jsonb. The old script also set the integer
  twice, to `0` with a comment about allowing force pushes and then to
  `PROTECTION_FULL`; the second won, so the comment described nothing.
- **`sign_in_text` and `onboarding_enabled` are gone too.** The sign-in text's
  successor is the Appearance record's `description`.
- **Do not set an Appearance without reading `OC::AppearancesHelper` first.**
  The fork's sign-in brand column renders through `custom_sign_in_description`,
  which defers to `current_appearance.description` when one exists, and its
  logo through `brand_image_path`/`brand_header_logo`, which defer to the
  appearance's `logo`/`header_logo`. Creating an Appearance row to brand the
  instance therefore *replaces* the fork's own branding rather than adding to
  it. There is no Appearance row on a fresh GDK, which is why the fork's
  branding shows.
- **Turning service ping off takes two columns, not one.**
  `GitlabServicePingWorker` guards on `usage_ping_generation_enabled?`, whose
  reader is `usage_ping_enabled? || super` — an OR over a *second* column that
  also defaults to true. Setting only `usage_ping_enabled: false` leaves the
  worker generating and submitting, because the `return if Gitlab.com?` above
  `SubmitService` does not fire on a self-managed instance. With both false the
  worker returns immediately (verified: `perform` returns nil in 4ms and writes
  no `RawUsageData` row). `include_optional_metrics_in_service_ping` is inert
  in this edition — `usage_ping_features_enabled` only consults it under
  `if Gitlab.ee?` — and is set only so the row is right if EE ever loads.
  `gitlab_product_usage_data_enabled` is the separate Snowplow gate, read by
  `Gitlab::Tracking::EventEligibilityChecker`.
- **`version_check_enabled: false` does not stop the version check.**
  `Gitlab::Version::VersionCheckCronWorker#perform` has no settings guard at
  all: it GETs `version.gitlab.com` on its cron schedule regardless and caches
  the result. The setting is read only by `VersionCheckHelper.show_version_check?`,
  which decides whether the badge renders. Stopping the request needs the cron
  entry gone or the worker overridden — `apply_user_overrides` in
  `Gitlab::SidekiqConfig::CronJobs` skips nil values, so a `cron: ~` in
  `gitlab.yml` will not do it.

### A runner for deployment jobs

Deployments only *run* with a CI runner attached, which a GDK has none of by
default. What that took, since none of it is obvious from a failure:

- **Docker executor, not shell.** The pipeline declares `image: $DEPLOY_IMAGE`
  and its script runs `unfurl`, terraform and ansible from that image; a shell
  executor ignores `image:` and runs against the developer's own home.
- **`extra_hosts = ["gdk.test:host-gateway"]` in the runner's `config.toml`.**
  Without it a job container cannot resolve `gdk.test`, so the clone and every
  callback fail. Docker on macOS proxies to the host's loopback, so the GDK
  does **not** need rebinding off 127.0.0.1 — check before changing
  `--ip` on `gitlab-http-router`, which would expose the instance to the
  network for no reason.
- **Register with a runner created server-side.** 19.x removed the legacy
  registration-token flow, so a runner binary older than 15.10 cannot register
  at all (a stale `gitlab-runner` on `PATH` is the trap; match the server's
  version). Create the runner with `Ci::Runners::CreateRunnerService`
  (`runner_type: 'instance_type'`, `run_untagged: true`) and register with its
  token. **Instance-level**, because the cypress harness mints a fresh
  dashboard project per run and a project runner would not cover it.
- **`DEPLOY_IMAGE` belongs in an instance CI variable.** `onecommons/ci`
  hardcodes `onecommons/unfurl:latest`, which is not the image to deploy with.
  An instance variable overrides it without editing the seeded copy:
  `Builder#scoped_variables` concatenates `job.yaml_variables` *before*
  `user_defined_variables`, which leads with instance variables, and last wins.
  `Gitlab::Ci::Build::Image` stores the name verbatim, so `$DEPLOY_IMAGE`
  reaches the runner unexpanded and is expanded there from the job's variables.
  Verified with a job whose YAML set the variable and whose trace reported the
  instance value.
- **Do not run two runners against one `config.toml`.** A `gitlab-runner`
  launchd agent with no `--config` defaults to `~/.gitlab-runner/config.toml`
  and reloads it on change, so an old service silently starts competing for
  jobs under the same token. `brew services list` is where to look.

`UNFURL_SERVICES_URL` is a red herring for this: the pipeline sets it to
`${CI_SERVER_URL}/services`, and its only consumers are the `project-dns`
service and an `api_root` baked into deployed API-gateway resources. Neither is
the Unfurl server, and neither is reachable on a GDK. It does not need fixing
for a deployment to run.

Deploying also needs the user's dashboard project. `OC::User#create_dashboard_project!`
builds it from the `unfurl_dashboard` template, but only
`OC::RegistrationsController` enqueues the worker that calls it, so a user made
by an admin, the API or a seed has none — deliberately, per the comment there.
Give an existing user one with
`OC::Onboarding::CreateDashboardProjectWorker.new.perform(user.id)`, or push a
repository containing `unfurl.yaml`, which `computed_unfurl_type` classifies on
its own. `bundle exec rake db:seed_fu FILTER=unfurl_blueprints` imports a
blueprint project to look at (`oc/db/fixtures/development/`).

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
- A *new* class in a namespace upstream owns takes the upstream constant and
  the plain path, exactly as `ee/` does: a fork Grape endpoint is
  `oc/lib/api/<name>.rb` defining `API::<Name>`, not `oc/lib/oc/api/`, which is
  the extension-module tree. The same split runs through `oc/app`:
  `oc/app/controllers/projects/unfurl_deployments_controller.rb` defines
  `Projects::UnfurlDeploymentsController`, while `oc/app/controllers/oc/**`
  holds the modules that prepend onto upstream controllers. The generated cop exclusions follow that split, so
  a Grape class in the wrong tree fails lint on cops upstream exempts for
  `lib/api`. Mount it from a `prepended` block in `oc/lib/oc/api/api.rb` —
  `lib/api/api.rb` ends in `API::API.prepend_mod`, so no in-place edit is
  needed even when the class you meant to extend lost its own hook.
- A new API route needs `route_setting :authorization` (a `permissions:` /
  `boundary_type:` pair, or a `skip_granular_token_authorization:` reason from
  `lib/tasks/gitlab/permissions/routes/skip_reasons.rb`). CI runs
  `bundle exec rake gitlab:permissions:validate`, which walks every mounted
  route; the fork's spec tree is not in its coverage scanner, so reuse a
  permission an upstream endpoint already declares.
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

### GitLab's own marketing

Promotions are removed **in place**, in the upstream file, with an `OC Change`
marker — not by an `oc/` override and not by CSS. The difference is how each
fails when upstream moves: an in-place edit conflicts at rebase and says so, an
`oc/` copy keeps rendering a stale duplicate after upstream changes the
original, and a CSS rule silently stops matching when a class is renamed, which
GitLab does every release.

Most of GitLab's promotional surfaces never render here, so check before
touching one: `Gitlab.ee?` is false, which removes every EE upsell and trial
surface, `Gitlab.com?` is false, which removes anything gated that way (the
third-party offers on the new project form are `|| !Gitlab.com?`), and the
instance script sets `hide_third_party_offers`. What is left is the residue —
CE promotions gated on neither. Removed so far: the Jira promotion on the empty
issue list, the console hello message (call site only, in `main.js`), and the
subscription upsell in alert settings, which was reworded rather than deleted
because it was also the only explanation for a disabled control.

An upstream jest spec that asserts a removed promotion renders is edited in
place with a `// OC Change` comment, like any other upstream spec the fork
invalidates. Invert it to assert the promotion is *absent* rather than deleting
the examples: that way a rebase which reinstates the promotion fails in CI.

That is also the limit of what is mechanical. The markers catch upstream
*changing or removing* something already dealt with; nothing catches upstream
*adding* a new promotion, and no test can, since there is no predicate for "is
this marketing" — a text match on a vendor name hits that vendor's real
integration UI. Finding new ones is a rebase-time audit step.

### Gotchas

- **A gem the fork calls *directly* can change under an unchanged call.** The
  port bumps every dependency, and a gem that keeps a method's signature while
  changing what it returns fails silently: nothing raises, the diff shows
  nothing, and no spec covers the difference. `gitlab-markup` 1.9 carried a
  markdown handler and 2.1 dropped it, so the dashboard's
  `GitHub::Markup.render` began returning a `.md` readme unchanged and the page
  rendered its own source — into `v-html`, so unrendered meant unsanitised too.
  Calls routed through GitLab's own wrappers are covered by upstream's specs;
  it is the direct ones to audit on a version bump. There are two:
  `GitHub::Markup`, now replaced by `Markup::RenderingService`, and Octokit in
  `OC::Repositories::PullMirrors::Webhook::GithubService`, which survived
  4.25 → 9.2 only because its QA spec runs against live GitHub.
- **Inside `module OC`, write `::Gitlab::...`.** A bare `Gitlab::` resolves to
  `OC::Gitlab`, which exists because of `oc/lib/oc/gitlab/sidekiq_config.rb`.
  The failure looks like `uninitialized constant OC::Gitlab::Json`.
- **A bare `Environment` inside `module OC` is `OC::Environment`,** the
  extension module, not the upstream class. Same trap as `Gitlab::` above, and
  it arrived with `oc/app/models/oc/environment.rb`. Write `::Environment`.
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
  new code under an existing context where one fits (`Gitlab` is the
  platform context, so a pre-receive check goes under `OC::Gitlab::Checks`
  like upstream's); a fork-only namespace needs an entry there, and that
  entry is a rebase conflict every release. Extension modules named after an
  upstream class (`OC::Project`, `OC::Notes::UpdateService`) cannot comply;
  every new one needs a line in `oc/rubocop/extension_modules.yml`.
- **New or renamed Sidekiq workers** require regenerating
  `oc/app/workers/all_queues.yml`, or CI fails:

  ```bash
  RAILS_ENV=test bin/rake gitlab:sidekiq:all_queues_yml:generate
  ```

  Do not regenerate `config/sidekiq_queues.yml`: upstream generates it in EE
  mode and checks it only there (`EEOnlyTask` in `scripts/static-analysis`),
  and regenerating it as `oc` strips every EE queue. Add the new worker's
  queue by hand under its `# OC Change` marker instead, since
  `spec/workers/every_sidekiq_worker_spec.rb` wants every queue listed. A
  worker's `feature_category` must be one of the values in
  `config/feature_categories.yml`; a non-default `sidekiq_options retry:`
  goes in `OC::EverySidekiqWorkerTestHelper#extra_retry_exceptions`
  (`oc/spec/support/helpers/oc/`); `urgency :low` needs
  `defer_on_database_health_signal`; `data_consistency :always` is refused,
  use `:sticky`. Cron schedules go in `oc/config/schedule.yml`, loaded beside
  `config/schedule.yml`.
- **`oc/rubocop/rubocop-oc.yml` is generated.** It gives every `ee/` and `jh/`
  Include/Exclude entry in `.rubocop.yml` and `rubocop/*.yml` an `oc/` twin
  (`ee/lib/ee/api/**` becomes `oc/lib/oc/api/**`). Rerun `ruby oc/scripts/generate_rubocop_config.rb` after an upstream bump;
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
- **A Vue 2/3 error nothing explains: delete `tmp/infection_scanner.json`
  first.** The graph is written to disk and reloaded on every rspack start, and
  a scan taken while `node_modules` was mid-`yarn install` records import edges
  as `resolved: null`. Those dependencies then never take `?vue3`, and a
  Vue-3-only one fails as `export 'Fragment' was not found in 'vue'` — which
  names Vue, the bundler, and any linked checkout, but never the graph. It
  survives restarts, so it looks like a code problem and invites elaborate
  theories. `warnUnclassifiedOcPagesDeps` now prints the affected packages at
  scan time.

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
  nothing queries inside these values anyway. **An encrypted attribute is the
  exception:** `Gitlab/Rails/AttrEncrypted` forbids new `attr_encrypted`, and
  `doc/development/migration_style_guide.md` says an `encrypts` attribute must
  be `jsonb`, not `text`. Those columns carry no validator — neither do
  upstream's own — and the example that would object is quarantined.
- **Prefer real foreign keys over a polymorphic pair: every column ending in
  `_id` needs one** or an entry in `ignored_fk_columns_map` in that same
  upstream spec. Where neither is possible — the target is in a schema this one
  may not reference, or is not a local record at all — **name the column so it
  does not end in `_id`**, which is a fork-local decision rather than an
  upstream edit. `oc_environment_providers` has both cases:
  `role_external_ref` (the AWS ExternalId, denormalised from `aws_roles`, which
  is `gitlab_main_user`) and `gcp_project` (a Google project, not a row here).
- **Run migrations with a matching `pg_dump` on `PATH`.**
  `RAILS_ENV=test bin/rake db:migrate` applies the migration to the `main`,
  `ci` and `sec` test databases, writes `db/schema_migrations/<version>`, then
  dumps `db/structure.sql`; a `pg_dump` of another major version (Homebrew's,
  say) aborts that last step after the migration has run. Reverting is per
  database: `db:migrate:down:main VERSION=<version>`, then `ci` and `sec`.
- **Commit the dump as written — do not hand-pick statements.** An earlier
  revision of this bullet said Postgres 17's `pg_dump` reorders partitioned
  tables and moves hundreds of unrelated lines, so you had to insert your
  statements by hand. Measured on 2026-09-13 that is not what happens:
  `oc_blueprint_deployments` produced 31 insertions in 6 regions and nothing
  else. The whole diff was the new table, its sequence, its default, its
  primary key, its two indexes and its two foreign keys.

  The reason is what the dump reads. `db:schema:dump` dumps a *database*, not
  your migrations, and the **test** databases are built by loading
  `structure.sql`, so their contents are the committed schema plus your
  migration — exactly the right input. The *development* database is not:
  this GDK's was created on `master` before the branch was cut, so it carries
  167 migrations that do not exist on the branch, and dumping it produces a
  diff full of things you did not do. That is what made this look
  non-deterministic. It is not; the input was simply wrong.

  So, with mise's `postgres` bin on `PATH` for a matching `pg_dump`:

  ```bash
  RAILS_ENV=test bin/rake db:migrate db:schema:dump
  git diff --stat db/structure.sql   # expect only your table
  ```

  Check the diff before committing it. If it does contain unrelated churn,
  the test databases have drifted from `structure.sql` — rebuild them with
  `RAILS_ENV=test bin/rake db:drop db:create db:schema:load` rather than
  editing the file by hand.

- **Two upstream guard specs cannot pass in this edition, and neither is
  about your table.** `spec/db/schema_spec.rb`'s jsonb-validator example fails
  for ~30 `ApplicationSetting` columns whose `JsonSchemaValidator` is declared
  in `ee/app/models/ee/application_setting.rb`, and `rake
  gitlab:permissions:validate` aborts on EE permission definition files. Both
  are EE code that never loads here. Check a failure names *your* table before
  chasing it.

### Project templates

`OC::Gitlab::ProjectTemplate` replaces upstream's table rather than appending
to it, and `OC::Gitlab::SampleDataTemplate` empties the sample one, so the five
Unfurl templates are the whole picker. Upstream examples that name `rails` or
`sample` therefore carry an `# OC Change`.

`unfurl_dashboard` and `unfurl_testbed` are vendored archives, rebuilt from
`main` of their projects on unfurl.cloud by

```bash
bundle exec rake 'gitlab:oc:update_project_templates[unfurl_dashboard]'
```

which replaces the manual export in cloud-dev-ensemble's
`project-templates/README.md` and applies that README's two invariants
(visibility, `forward_deployment_enabled: false`) in code. The three blueprint
entries are links to their projects; their archives are carried over from the
15.11 fork and are not maintained by the task.

Template logos go under `oc/app/assets/images/illustrations/`: sprockets only
auto-precompiles the root `app/assets`, and `illustrations/*.svg` is one of the
few globs `config/application.rb` adds.

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

**When porting a feature from 15.11, look for its existing specs before writing
new ones** — in the fork's `oc/spec` *and* `oc/spec/frontend`. RSpec files are
named after the class under test, so a new one collides with the old and you
notice; Jest files are named after behaviour, so a fresh spec sits happily
beside the one you failed to bring across. Three were lost that way, all for
code that had been ported, including one for a file that had just been
rewritten. Jest specs reaching oc-pages need `oc-pages` in
`transformIgnoreNodeModules` (`jest.config.base.js`): the `oc/` tree gets there
through symlinks Jest resolves back into `node_modules`, and the failure reads
as `Cannot use import statement outside a module`.

Where tests belong:

- `oc/spec/support/**` — helpers and shared examples, loaded by
  `oc/spec/spec_helper.rb` before upstream's own, so an
  `OC::SomeHelper` module is in place when upstream's `SomeHelper.prepend_mod`
  runs.
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
- `qa/qa/specs/features/oc/**` — end-to-end, separate `qa/` bundle. Written
  with the `create(:project)` factories (`QA/FabricateUsage`) and a
  `feature_category`, not `product_group`. No CI job runs them yet.
- **User docs live in `oc/doc/`**, mirroring `doc/`. `OC::HelpController`
  serves a page from there before `doc/`, so `help_page_path('user/x.md')`
  resolves; the `Gitlab/DocumentationLinks/Link` cop looks there too
  (`# OC Change` in `rubocop/cop/gitlab/documentation_links/link.rb`).
  markdownlint applies as to `doc/`: labelled fences, `Git` not `git`,
  headings one level at a time.
