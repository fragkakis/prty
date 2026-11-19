#!/bin/bash
# Prints the "What's changed" part of a release's notes: the commit subjects since the
# previous tag, minus chore/docs/test/ci. release.yml puts it above .github/release-notes.md.
# GitHub's --generate-notes lists merged PRs only, and commits here go straight to main.
# Usage: Scripts/release-changes.sh v1.2.3
set -euo pipefail

tag=$1
git rev-parse -q --verify "$tag^{commit}" > /dev/null || { echo "unknown tag: $tag" >&2; exit 1; }
repo=https://github.com/${GITHUB_REPOSITORY:-fragkakis/prty-time}
prev=$(git describe --tags --abbrev=0 "$tag^" 2> /dev/null || true)
changes=$(git log --no-merges --pretty='- %s' "${prev:+$prev..}$tag" |
  grep -Ev '^- (chore|docs|test|ci)(\(.*\))?!?:' || true)

echo "## What's changed"
echo
echo "${changes:-- Maintenance only.}"
echo
if [[ -n $prev ]]; then
  echo "**Full Changelog**: $repo/compare/$prev...$tag"
else
  echo "**Full Changelog**: $repo/commits/$tag"
fi
