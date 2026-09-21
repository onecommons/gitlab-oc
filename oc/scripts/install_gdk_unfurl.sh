#!/bin/sh
# Installs the GDK service that runs the Unfurl server, plus the cloudmap clone
# and database the service uses when they are there. Safe to re-run.
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
GITLAB_URL=${GITLAB_URL:-http://gdk.test:3000}
UPSTREAM_CLOUDMAP=${UPSTREAM_CLOUDMAP:-https://unfurl.cloud/onecommons/cloudmap.git}
CLOUDMAP=$GDK/tmp/cloudmap

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
