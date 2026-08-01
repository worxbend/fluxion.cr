#!/usr/bin/env bash
#
# Publishes site/ to the gh-pages branch.
#
# The branch is rewritten as a single orphan commit each time: it is build
# output, not history, and a growing log of "publish site" commits is noise in
# a repository whose real history is the code.
#
#   ./scripts/publish-site.sh [--dry-run]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/site"
BRANCH="${PAGES_BRANCH:-gh-pages}"
REMOTE="${PAGES_REMOTE:-origin}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "$SOURCE/index.html" ]] || { echo "site/index.html is missing" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# Copy rather than publish the working tree directly, so an unrelated dirty
# file in site/ cannot end up on the live site by accident.
cp -R "$SOURCE"/. "$staging"/
touch "$staging/.nojekyll"

echo "Publishing $(find "$staging" -type f | wc -l) files to $REMOTE/$BRANCH:"
(cd "$staging" && find . -type f | sed 's|^\./|  |' | sort)

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "Dry run: nothing was committed or pushed."
  exit 0
fi

revision="$(git -C "$ROOT" rev-parse --short HEAD)"

cd "$staging"
git init --quiet -b "$BRANCH"
git add -A
git commit --quiet -m "Publish site from $revision"
git push --quiet --force "$(git -C "$ROOT" remote get-url "$REMOTE")" "$BRANCH:$BRANCH"

echo "Published $BRANCH from $revision"
echo "https://worxbend.github.io/fluxion.cr/"
