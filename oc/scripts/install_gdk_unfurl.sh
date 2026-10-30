#!/bin/sh
# Installs the GDK service that runs the Unfurl server, its home project, plus
# the cloudmap clone and database the service uses when they are there. Safe to
# re-run.
#
#   sh oc/scripts/install_gdk_unfurl.sh [--skip-cloudmap]
#
# The service definition lives in this repo rather than in the GDK checkout
# because that checkout is upstream's: a file added there is untracked, and
# `gdk update` would eventually lose it. Copying it in is cheaper than forking
# the GDK to hold one file.
set -e

GDK=${GDK_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
# The address the service gives the server, from the same GDK config
# (lib/gdk/services/unfurl.rb's gitlab_url).
if [ -z "${GITLAB_URL:-}" ]; then
  GITLAB_URL=http://$(cd "$GDK" && gdk config get hostname):$(cd "$GDK" && gdk config get gitlab.rails.port)
fi
gitlab_host=${GITLAB_URL#*://}
gitlab_host=${gitlab_host%%[:/]*}
UPSTREAM_CLOUDMAP=${UPSTREAM_CLOUDMAP:-https://unfurl.cloud/onecommons/cloudmap.git}
CLOUDMAP=$GDK/tmp/cloudmap
# The server commits to and pushes whatever branch the clone is on, so this
# instance's records stay off upstream's main.
CLOUDMAP_BRANCH=${CLOUDMAP_BRANCH:-hosts/$gitlab_host}
HOME_PROJECT=$GDK/tmp/unfurl_home

case "${1:-}" in
  --skip-cloudmap) skip_cloudmap=1 ;;
  '') skip_cloudmap=0 ;;
  *) echo "usage: $0 [--skip-cloudmap]" >&2; exit 2 ;;
esac

# GDK discovers services by reflection over GDK::Services, so the file landing
# here is the whole registration -- no list to edit, and `gdk start` renders
# the run script itself.
mkdir -p "$GDK/lib/gdk/services"
cp "$REPO/oc/scripts/unfurl.rb" "$GDK/lib/gdk/services/unfurl.rb"
echo "installed  $GDK/lib/gdk/services/unfurl.rb"

# The server's home project (`unfurl --home`, see unfurl.rb). Written only when
# missing, so an edit made there survives a re-run.
if [ -f "$HOME_PROJECT/unfurl.yaml" ]; then
  echo "present    $HOME_PROJECT/unfurl.yaml"
else
  mkdir -p "$HOME_PROJECT"
  cat > "$HOME_PROJECT/unfurl.yaml" <<YAML
# The GDK unfurl server's home project; see lib/gdk/services/unfurl.rb.
# Only what the server needs, so nothing from a personal ~/.unfurl_home leaks in.
apiVersion: unfurl/v1alpha1
kind: Project
environments:
  defaults:
    cloudmaps:
      hosts:
        # The GitLab instance calling this server: lets POST /cloudmap/analyze
        # read its projects' metadata.
        gdk:
          type: gitlab
          url: $GITLAB_URL
          # Key records as git://unfurl.cloud/..., so the GDK's projects match
          # the records the real instance's projects have.
          canonical_url: https://unfurl.cloud
YAML
  echo "created    $HOME_PROJECT/unfurl.yaml"
fi

if [ "$skip_cloudmap" = 1 ]; then
  echo "skipped    cloudmap clone and database"
else
  # UNFURL_CLOUDMAP_REPO is a working tree, not a URL: the server exits
  # non-zero when the path is not one. ls-remote rather than a health check --
  # it tests the one thing the clone needs.
  if [ -d "$CLOUDMAP/.git" ]; then
    echo "present    $CLOUDMAP"
  elif git ls-remote --exit-code "$GITLAB_URL/onecommons/cloudmap.git" HEAD >/dev/null 2>&1; then
    git clone "$GITLAB_URL/onecommons/cloudmap.git" "$CLOUDMAP"
  else
    echo "$GITLAB_URL is not answering; cloning the public copy instead"
    git clone "$UPSTREAM_CLOUDMAP" "$CLOUDMAP"
    git -C "$CLOUDMAP" remote set-url origin "$GITLAB_URL/onecommons/cloudmap.git"
    echo "origin now points at $GITLAB_URL -- pull once the GDK is up"
  fi

  # The server reads the branch when it opens the clone, so a switch needs
  # `gdk restart unfurl`. Plain `git switch` tracks the remote's branch if
  # one was pushed. Not `switch -C`: that resets an existing branch.
  git -C "$CLOUDMAP" switch -q "$CLOUDMAP_BRANCH" 2>/dev/null ||
    git -C "$CLOUDMAP" switch -q -c "$CLOUDMAP_BRANCH"
  echo "on branch  $CLOUDMAP_BRANCH"

  # unfurl-git-sync migrates its own tables on first start but never issues
  # CREATE DATABASE, and createdb fails when the database is already there.
  # The name has to match cloudmap_db_url in unfurl.rb -- the server does not
  # complain about the wrong database, it just indexes nothing into it.
  if psql -h "$GDK/postgresql" -d postgres -Atc \
      "select 1 from pg_database where datname = 'unfurl_cloudmap'" | grep -q 1; then
    echo "present    database unfurl_cloudmap"
  else
    createdb -h "$GDK/postgresql" unfurl_cloudmap
    echo "created    database unfurl_cloudmap"
  fi
fi

echo
echo "Next: gdk start unfurl   (log: gdk tail unfurl)"
