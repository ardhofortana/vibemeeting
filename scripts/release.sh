#!/bin/bash
# Makes a release: moves the [Unreleased] notes in CHANGELOG.md under the new
# version, sets MARKETING_VERSION and the next CURRENT_PROJECT_VERSION in
# project.yml, commits, and tags vX.Y.Z. Usage:
#   scripts/release.sh 0.6.0
# Then push with: git push origin HEAD --follow-tags
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh X.Y.Z (for example 0.6.0)"
  exit 1
fi
# The [Unreleased] notes may still be uncommitted; the release commit takes them.
if ! git diff --quiet -- . ':(exclude)CHANGELOG.md' || ! git diff --cached --quiet -- . ':(exclude)CHANGELOG.md'; then
  echo "Commit or stash your changes first (only CHANGELOG.md may be uncommitted)."
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "Tag v$version already exists."
  exit 1
fi
if grep -qF "## [$version]" CHANGELOG.md; then
  echo "$version is already in CHANGELOG.md."
  exit 1
fi

# Compare links point at the repo this clone came from (an https or ssh remote).
origin=$(git remote get-url origin 2>/dev/null || true)
repo=$(sed -E 's#^git@([^:]+):#https://\1/#; s#^ssh://git@([^/]+)/#https://\1/#; s#^https://[^/@]+@#https://#; s#\.git$##; s#/$##' <<<"$origin")
if ! [[ "$repo" =~ ^https://[^/]+/[^/]+/[^/]+$ ]]; then
  echo "Can't make the CHANGELOG compare links: origin is \"$origin\". Add the GitHub remote as origin first."
  exit 1
fi

notes=$(awk '/^## \[Unreleased\]/ { f = 1; next } /^## \[/ { f = 0 } f' CHANGELOG.md | grep -v '^[[:space:]]*$' || true)
if [ -z "$notes" ]; then
  echo "CHANGELOG.md has nothing under [Unreleased]. Write what changed there first."
  exit 1
fi

previous=$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | sed -E 's/^## \[([^]]+)\].*/\1/')
newest=$(printf '%s\n%s\n' "$previous" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
if [ "$newest" != "$version" ]; then
  echo "$version is not newer than $previous."
  exit 1
fi
build=$(( $(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *([0-9]+).*/\1/p' project.yml) + 1 ))
today=$(date +%Y-%m-%d)

# project.yml (sed -i.bak works with both BSD and GNU sed)
sed -i.bak -E "s/^( *MARKETING_VERSION: *).*/\1$version/; s/^( *CURRENT_PROJECT_VERSION: *).*/\1$build/" project.yml
rm -f project.yml.bak

# CHANGELOG.md: a heading for the new version under [Unreleased], and its compare link
awk -v v="$version" -v d="$today" -v p="$previous" -v r="$repo" '
  /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
  /^\[Unreleased\]: / { print "[Unreleased]: " r "/compare/v" v "...HEAD"; print "[" v "]: " r "/compare/v" p "...v" v; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

git add project.yml CHANGELOG.md
git commit -q -m "Release $version"
git tag -a "v$version" -m "VibeMeeting $version"
echo "Released $version (build $build) and tagged v$version."
echo "Push it with: git push origin HEAD --follow-tags"
