#!/bin/sh
# Tags a release and pushes the tag to the GitLab mirror CNG builds from, then
# to GitHub, where cng-release.yml builds its images.
#
#   sh oc/scripts/release.sh [--dry-run] [--force] [<tag>] [commit]
#
# Tags are <VERSION>-<YY-MM-DD><letter>, e.g. 19.3.0-rc42-26-10-30a, the
# letter counting releases that day. Without a tag, the next one for today is
# used. The tag is what unfurl.cloud/help shows as the current version.
#
# The commit must already be on GitHub's main, which only gets commits that
# passed CI; --force releases one that isn't.
#
# The mirror goes first: cng-release.yml checks it has the tag before
# triggering anything. The first push there carries the history since 15.11
# (about 1.2 GiB).
set -eu
cd "$(dirname "$0")/../.."

MIRROR=${MIRROR:-git@gitlab.com:onecommons/gitlab-foss.git}
GITHUB_REMOTE=${GITHUB_REMOTE:-origin}
RELEASE_BRANCH=${RELEASE_BRANCH:-main}
# Keep in step with on.push.tags in .github/workflows/cng-release.yml.
VERSION_RE='[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?'
TAG_RE="^$VERSION_RE-[0-9]{2}-[0-9]{2}-[0-9]{2}[a-z]\$"

run=
force=0
while :; do
  case "${1:-}" in
    --dry-run) run='echo'; shift ;;
    --force) force=1; shift ;;
    *) break ;;
  esac
done
if [ $# -gt 2 ]; then
  echo "usage: $0 [--dry-run] [--force] [<tag>] [commit]" >&2
  exit 2
fi
sha=$(git rev-parse --verify "${2:-HEAD}^{commit}")

git fetch -q "$GITHUB_REMOTE" "$RELEASE_BRANCH"
if ! git merge-base --is-ancestor "$sha" FETCH_HEAD; then
  if [ "$force" = 1 ]; then
    echo "warning: $sha is not on $GITHUB_REMOTE/$RELEASE_BRANCH" >&2
  else
    echo "$sha is not on $GITHUB_REMOTE/$RELEASE_BRANCH; push it there first, or pass --force" >&2
    exit 1
  fi
fi
if [ "$sha" = "$(git rev-parse HEAD)" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "warning: uncommitted changes are not part of the release" >&2
fi

if [ -n "${1:-}" ]; then
  tag=$1
  if ! printf '%s' "$tag" | grep -Eq "$TAG_RE"; then
    echo "$tag is not <VERSION>-<YY-MM-DD><letter>" >&2
    exit 1
  fi
else
  version=$(git show "$sha:VERSION")
  if ! printf '%s' "$version" | grep -Eq "^$VERSION_RE\$"; then
    echo "VERSION is $version, not MAJOR.MINOR.PATCH[-rcN]" >&2
    exit 1
  fi
  prefix=$version-$(date +%y-%m-%d)
  taken=$({
    git tag -l "$prefix?"
    git ls-remote --tags "$GITHUB_REMOTE" "refs/tags/$prefix?" "refs/tags/$prefix?^{}"
    git ls-remote --tags "$MIRROR" "refs/tags/$prefix?"
  } | sed 's|.*refs/tags/||; s|\^{}$||')
  tag=
  for letter in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
    if ! printf '%s\n' "$taken" | grep -qx "$prefix$letter"; then
      tag=$prefix$letter
      break
    fi
  done
  if [ -z "$tag" ]; then
    echo "every $prefix<letter> tag is taken" >&2
    exit 1
  fi
fi

if existing=$(git rev-parse -q --verify "refs/tags/$tag^{commit}"); then
  if [ "$existing" != "$sha" ]; then
    echo "$tag already tags $existing, not $sha" >&2
    exit 1
  fi
  echo "using      existing tag $tag ($sha)"
else
  $run git tag -a "$tag" -m "Release $tag" "$sha"
  echo "tagged     $tag ($sha)"
fi

$run git push --no-verify --no-follow-tags "$MIRROR" "refs/tags/$tag"
$run git push --no-verify --no-follow-tags "$GITHUB_REMOTE" "refs/tags/$tag"
echo "CNG build: https://github.com/onecommons/gitlab-oc/actions/workflows/cng-release.yml"
