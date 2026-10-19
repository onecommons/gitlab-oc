#!/usr/bin/env bash
# Replaces GDK's support/gdk-in-a-box/container/install-config-gdk.sh when
# gdk-image.yml builds the base image: the same install, but of this fork
# rather than GitLab's EE repository, so no layer of the published image holds
# EE code.

set -euo pipefail

eval "$(~/.local/bin/mise activate bash)"

# GDK's yarn step passes --pure-lockfile, which the fork's Yarn Berry rejects.
# The marker makes make skip it; oc/support/ci/Dockerfile runs the real install.
touch .gitlab-yarn

mise x -- gdk install treeless_clone=true gitlab_repo="https://github.com/onecommons/gitlab-oc.git" telemetry_user="gdk-in-a-box"
mise x -- gdk config set hostname gdk.local
mise x -- gdk config set listen_address 0.0.0.0
mise x -- gdk reconfigure
mise x -- gdk truncate-legacy-tables
mise x -- gdk stop
