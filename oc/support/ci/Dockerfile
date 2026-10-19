# A GDK running this fork, for CI.
#
# Built on GDK-in-a-Box rather than a recipe of our own: gdk-image.yml builds
# GDK's current support/gdk-in-a-box/container Dockerfile, so the toolchain and
# the Postgres/Redis/Gitaly infrastructure stay current without us maintaining
# them. The fork's own 2021 image went stale precisely because it did not
# inherit anything.
#
# Not GitLab's published image, though: its checkout is GitLab EE, and a layer
# keeps that whatever a later one deletes. The base swaps in
# install-config-gdk.sh so GDK installs this fork instead.
ARG GDK_BASE=ghcr.io/onecommons/gitlab-oc/gdk:base
FROM ${GDK_BASE}

ARG OC_REF=main

WORKDIR /gitlab-gdk/gitlab-development-kit
SHELL ["/bin/bash", "-c"]

# gdk.test, the hostname a developer's GDK uses and unfurl-gui's cypress README
# assumes, so CI runs the same commands. Never localhost, which flips
# integration-test.js into standalone mode. Reconfigured so no generated file
# keeps the base's gdk.local.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk config set hostname gdk.test \
    && mise x -- gdk config set listen_address 0.0.0.0 \
    && mise x -- gdk reconfigure

# The base's checkout is the fork's default branch as of the base build.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && git fetch --depth=1 origin "${OC_REF}" \
    && git checkout -B "${OC_REF}" FETCH_HEAD

# The base installed the gems, so bundle install mostly no-ops; it skipped the
# Node modules (see install-config-gdk.sh), and with them the JS translations
# gettext:compile writes.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && bundle install --jobs 4 \
    && yarn install --immutable \
    && bin/rake gettext:compile

# The base's gdk install created and seeded the database from the fork, so this
# only migrates to OC_REF and applies the instance settings the fork needs.
# Kept as a script in the repo so the image and a developer's own GDK are
# configured the same way -- see "Instance settings" in .ai/oc.md. The status
# is kept across `gdk stop` so a failure fails the build.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk start postgresql redis \
    && cd gitlab \
    && { RAILS_ENV=development bin/rake db:migrate \
         && RAILS_ENV=development bin/rake db:seed_fu FILTER=unfurl_blueprints \
         && RAILS_ENV=development UNFURL_SERVER_URL=http://gdk.test:8081 \
            bin/rails runner oc/support/ci/instance_settings.rb; } \
    ; status=$?; mise x -- gdk stop; exit $status

# The base created the test databases too; reload them so they match OC_REF.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk start postgresql redis \
    && cd gitlab \
    && { RAILS_ENV=test bin/rake db:drop db:create db:schema:load; } \
    ; status=$?; mise x -- gdk stop; exit $status

# The test Gitaly, Workhorse and fixture repositories, as upstream CI prepares
# them; otherwise every spec run compiles them first, ~7 minutes. What the
# build leaves goes in the same layer, or the image keeps it: Go's module and
# build caches (~2.2 GB, redirected so the base's own stay), Gitaly's build
# cache and bundled Git's build trees (~1.6 GB), and the binaries the started
# Gitaly unpacked under tmp/run. TestEnv only checks the checkout's .git,
# VERSION and _build/bin before deciding to rebuild.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && export GOMODCACHE=/tmp/go-mod GOCACHE=/tmp/go-build \
    && RAILS_ENV=test scripts/setup-test-env \
    && { chmod -R u+w /tmp/go-mod 2>/dev/null || true; } \
    && rm -rf /tmp/go-mod /tmp/go-build tmp/run/gitaly-* \
        tmp/tests/gitaly/_build/cache tmp/tests/gitaly/_build/deps

# Assets last: the slowest layer, and the one most likely to be invalidated.
# Rspack, as the GDK runs it: only its config knows how to resolve the oc-pages
# package. Called directly because package.json's build script is an if/else
# Yarn Berry's shell cannot run. The base wrote an infection scanner graph
# before node_modules existed, and the build reuses it rather than rescanning.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && rm -f tmp/infection_scanner.json \
    && yarn run rspack

# The GDK's redis listens on a unix socket and nothing else -- its template is
# three lines and the first is `port 0` -- so nothing outside the container can
# reach it. Appending wins over the earlier directive, which keeps this working
# whatever the base image's template says. Both files, because a `gdk
# reconfigure` at startup would rewrite the generated one from the template.
#
# Reachable from the host only: the container publishes this port and is thrown
# away with the job.
RUN printf '\n# OC Change -- reachable from the e2e unfurl server\nport 6379\nbind 0.0.0.0\nprotected-mode no\n' > /tmp/redis-oc \
    && cat /tmp/redis-oc >> components/redis/redis.conf.erb \
    && if [ -f redis/redis.conf ]; then cat /tmp/redis-oc >> redis/redis.conf; fi \
    && rm /tmp/redis-oc

# Most of a developer GDK's 18 GB is disposable: logs regrow at ~1.4 GB/day,
# the Yarn cache has done its job, and .gem archives and rdoc are never read.
#
RUN eval "$(~/.local/bin/mise activate bash)" \
    && rm -rf /gitlab-gdk/gitlab-development-kit/gitlab/log/* \
    && rm -rf ~/.cache/yarn ~/.yarn/berry/cache \
    && rm -rf "$(gem env gemdir)"/cache "$(gem env gemdir)"/doc 2>/dev/null || true

CMD ["/home/gdk/gdk-container-startup.sh"]
