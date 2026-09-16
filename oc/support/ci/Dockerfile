# A GDK running this fork, for CI.
#
# Built on GitLab's own GDK-in-a-Box image rather than a copy of its
# Dockerfile: that image is rebuilt by GDK's pipelines continuously, so the
# toolchain, the GDK install and the Postgres/Redis/Gitaly infrastructure stay
# current without us maintaining a recipe. The fork's own 2021 image went stale
# precisely because it did not inherit anything.
#
# What is NOT inherited: their checkout tracks gitlab master, this fork is cut
# from 19.3, so gems, modules, schema and assets are all rebuilt below. Their
# database cannot be migrated backwards and is dropped rather than reused.
ARG GDK_BASE=registry.gitlab.com/gitlab-org/gitlab-development-kit/gitlab-gdk-in-a-box:main
FROM ${GDK_BASE}

ARG OC_REPO=https://github.com/onecommons/gitlab-oc.git
ARG OC_REF=v19.3.0-oc

WORKDIR /gitlab-gdk/gitlab-development-kit
SHELL ["/bin/bash", "-c"]

# gdk.test rather than their gdk.local, because that hostname is the contract
# with the cypress harness -- and it must not be localhost, which flips
# integration-test.js into standalone mode.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk config set hostname gdk.test \
    && mise x -- gdk config set listen_address 0.0.0.0

# Point the checkout at the fork. A treeless clone still fetches a foreign
# ref, and the object overlap with upstream is large, so this is cheaper than
# it looks.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && git remote add oc "${OC_REPO}" \
    && git fetch --depth=1 oc "${OC_REF}" \
    && git checkout -B "${OC_REF}" FETCH_HEAD

# The fork's Gemfile is near-upstream's, so most gems are already present; the
# lockfile is Yarn Berry with an oc-pages git dependency, so modules are not.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && bundle install --jobs 4 \
    && yarn install --immutable

# Schema, seeds and the instance settings the fork needs. Kept as a script in
# the repo so the image and a developer's own GDK are configured the same way
# -- see "Instance settings" in .ai/oc.md.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk start postgresql redis \
    && cd gitlab \
    && RAILS_ENV=development bin/rake db:drop db:create db:schema:load \
    && RAILS_ENV=development bin/rake db:migrate \
    && RAILS_ENV=development bin/rake db:seed_fu \
    && RAILS_ENV=development bin/rake db:seed_fu FILTER=unfurl_blueprints \
    && RAILS_ENV=development bin/rails runner oc/support/ci/instance_settings.rb \
    && mise x -- gdk stop || true

# The test databases are separate from development and rspec will not create
# them for you. Cheap here, and the alternative is every spec run paying for it.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && mise x -- gdk start postgresql redis \
    && cd gitlab \
    && RAILS_ENV=test bin/rake db:create db:schema:load \
    && mise x -- gdk stop || true

# Assets last: the slowest layer, and the one most likely to be invalidated.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && cd gitlab \
    && yarn build

# Most of a developer GDK's 18 GB is disposable: logs regrow at ~1.4 GB/day,
# the Yarn cache has done its job, and .gem archives and rdoc are never read.
#
# tmp/tests/gitaly stays, all 2.2 GB of it. Stripping it to the binaries looks
# free and is not: TestEnv#component_needs_update? reads VERSION from that
# folder and treats ENOENT as "needs rebuilding", so the suite would try to
# rebuild Gitaly from a source tree that is no longer there. The GDK's
# .cache/.gitaly_commit_sha can short-circuit that check, but it is consulted
# after .git and before VERSION, which makes it a coincidence to rely on
# rather than a guarantee.
RUN eval "$(~/.local/bin/mise activate bash)" \
    && rm -rf /gitlab-gdk/gitlab-development-kit/gitlab/log/* \
    && rm -rf ~/.cache/yarn ~/.yarn/berry/cache \
    && rm -rf "$(gem env gemdir)"/cache "$(gem env gemdir)"/doc 2>/dev/null || true

CMD ["/home/gdk/gdk-container-startup.sh"]
