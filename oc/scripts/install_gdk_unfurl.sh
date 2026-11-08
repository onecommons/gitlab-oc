#!/bin/sh
# Installs the GDK service that runs the Unfurl server, its home project, plus
# the cloudmap database and grant key the service uses when they are there.
# Safe to re-run.
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
GRANT_KEY=$GDK/tmp/unfurl_grant_key
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
for service in unfurl unfurl_backend; do
  cp "$REPO/oc/scripts/$service.rb" "$GDK/lib/gdk/services/$service.rb"
  echo "installed  $GDK/lib/gdk/services/$service.rb"
done

# The services run unfurl's Python and unfurl-server through these links, so
# a rebuild of either needs only a restart.
unfurl_python=$(sed -n '1s/^#!//p' "$(command -v unfurl)")
unfurl_server=$("$unfurl_python" -c \
  'from unfurl.server.serve import _find_rust_server_bin as f; print(f() or "")')
if [ -z "$unfurl_server" ]; then
  echo "no unfurl-server binary; build it with cargo build -p unfurl-server" >&2
  exit 1
fi
mkdir -p "$GDK/tmp/unfurl_bin"
# A script, not a link: a venv's python finds its venv next to the path it
# was run by.
rm -f "$GDK/tmp/unfurl_bin/python"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$unfurl_python" > "$GDK/tmp/unfurl_bin/python"
chmod +x "$GDK/tmp/unfurl_bin/python"
ln -sf "$unfurl_server" "$GDK/tmp/unfurl_bin/unfurl-server"
echo "linked     $GDK/tmp/unfurl_bin -> $unfurl_server"

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
  echo "skipped    cloudmap database and grant key"
else
  # The server migrates its own tables on first start, as the role this
  # creates; GDK's postgres trusts the socket, so neither needs a password.
  # The URL has to match cloudmap_db_url in unfurl.rb -- the server does not
  # complain about the wrong database, it just indexes nothing into it. A
  # database left from before the role existed is owned by another role, which
  # create-database warns about; drop it and re-run.
  UNFURL_CLOUDMAP_DB_URL="postgres://unfurl_cloudmap@localhost/unfurl_cloudmap?host=$GDK/postgresql" \
    "$unfurl_server" create-database
  echo "ensured    database unfurl_cloudmap"

  # Last, as unfurl.rb offers the database only once this exists. Replacing
  # it would make the grants already stored unreadable.
  if [ -f "$GRANT_KEY" ]; then
    echo "present    $GRANT_KEY"
  else
    (umask 077 && head -c 32 /dev/urandom > "$GRANT_KEY")
    echo "created    $GRANT_KEY"
  fi
fi

echo
echo "Next: gdk start unfurl unfurl-backend   (log: gdk tail unfurl unfurl-backend)"
