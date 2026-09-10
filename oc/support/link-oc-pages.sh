#!/bin/sh
# Points the oc-pages source directories at a local unfurl-gui checkout, so
# rspack builds what you are editing instead of the pinned package.
#
#   sh oc/support/link-oc-pages.sh ~/_dev/unfurl-gui
#
# To undo, restore the four symlinks and rebuild from the pin:
#
#   git restore oc/app/assets/javascripts/dashboard \
#               oc/app/assets/javascripts/project_overview \
#               oc/app/assets/javascripts/public_cloud \
#               oc/app/assets/javascripts/vue_shared
#   rm -f tmp/infection_scanner.json
#   gdk restart rspack
#
# Only those four symlinks change -- package.json and yarn.lock are untouched,
# and no `yarn install` runs. Dependencies keep coming from the pinned package
# in node_modules, which is what makes this work where a `link:` resolution does
# not; see "Developing against a local unfurl-gui checkout" in .ai/oc.md.
set -eu

cd "$(dirname "$0")/../.."

checkout=${1:-}
if [ -z "$checkout" ]; then
  echo "usage: sh oc/support/link-oc-pages.sh <path-to-unfurl-gui-checkout>" >&2
  exit 1
fi

if [ ! -d "$checkout" ]; then
  echo "no such directory: $checkout" >&2
  exit 1
fi

pkg=$(cd "$checkout" && pwd)/packages/oc-pages
if [ ! -d "$pkg" ]; then
  echo "no oc-pages package at $pkg" >&2
  exit 1
fi

dirs='dashboard project_overview public_cloud vue_shared'

for d in $dirs; do
  if [ ! -d "$pkg/$d" ]; then
    echo "$pkg is missing $d -- is that an unfurl-gui checkout?" >&2
    exit 1
  fi
done

for d in $dirs; do
  ln -sfn "$pkg/$d" "oc/app/assets/javascripts/$d"
done

# The infection scanner graph is written to disk and reloaded on every rspack
# start, so a graph taken before the swap outlives it and misclassifies these
# files. A stale one shows up as an unrelated Vue 2/3 error.
rm -f tmp/infection_scanner.json

echo "oc-pages now builds from $pkg"
echo "run: gdk restart rspack"
