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

In CI, `oc/spec` runs in the `rspec-oc unit pg17` and `rspec-oc integration
pg17` jobs.

## Jest

Jest discovers `oc/spec/frontend/**/*_spec.js` automatically
(`jest.config.base.js`). Run every OC frontend test:

```bash
yarn jest oc/spec/frontend
```

In CI these run in the existing `jest` job; there is no separate OC Jest job.
