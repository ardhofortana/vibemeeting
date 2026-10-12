#!/bin/bash
# Creates the vX.Y.Z tags for every version in CHANGELOG.md, so you can roll
# back with `git checkout vX.Y.Z`. Safe to run again: existing tags are kept.
#   scripts/tag-versions.sh
# A version's commit is the one named in its heading ("(commit abc1234)"), or
# else the commit that set its MARKETING_VERSION in project.yml (a release).
set -euo pipefail
cd "$(dirname "$0")/.."

created=0
while IFS= read -r heading; do
  version=$(sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/' <<<"$heading")
  tag="v$version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    continue
  fi
  commit=$(sed -nE 's/.*\(commit ([0-9a-f]{7,40})\).*/\1/p' <<<"$heading")
  if [ -z "$commit" ]; then
    # The oldest commit that changed the count of this line is the one that
    # introduced it (later releases remove it again).
    commit=$(git log --format=%H -S"MARKETING_VERSION: $version" -- project.yml | tail -n 1)
  fi
  if [ -z "$commit" ] || ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "Skipped $tag: its commit isn't in this clone (run git pull first)."
    continue
  fi
  git tag -a "$tag" "$commit" -m "VibeMeeting $version"
  echo "Tagged $tag at $(git rev-parse --short "$commit")"
  created=$((created + 1))
done < <(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md)

echo "$created new tag(s). Versions: $(git tag --list 'v*' --sort=version:refname | tr '\n' ' ')"
