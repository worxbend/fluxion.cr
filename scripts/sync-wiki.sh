#!/usr/bin/env bash
#
# Publishes wiki/ to the GitHub wiki.
#
# The wiki is a separate git repository that only materialises once its first
# page has been created through the web UI. There is no API for that step, so
# this script checks for it and says what to do rather than failing obscurely.
#
#   ./scripts/sync-wiki.sh [--dry-run]
#
set -euo pipefail

REPO="${WIKI_REPO:-git@github.com:worxbend/fluxion.cr.wiki.git}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wiki"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

checkout="$(mktemp -d)"
trap 'rm -rf "$checkout"' EXIT

if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO" "$checkout" 2>/dev/null; then
  cat >&2 <<EOF
The wiki repository does not exist yet.

GitHub creates it when the first page is saved through the web UI, and offers
no API for that step. Once, by hand:

  1. https://github.com/worxbend/fluxion.cr/wiki
  2. "Create the first page", save anything at all
  3. re-run this script — it overwrites that placeholder

EOF
  exit 1
fi

# Everything except README.md, which documents the source and not the wiki.
published=0
for page in "$SOURCE"/*.md; do
  name="$(basename "$page")"
  [[ "$name" == "README.md" ]] && continue
  cp "$page" "$checkout/$name"
  published=$((published + 1))
done

cd "$checkout"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "Wiki is already up to date ($published pages)."
  exit 0
fi

echo "Pages that would change:"
git status --porcelain | sed 's/^/  /'

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "Dry run: nothing was committed or pushed."
  exit 0
fi

git add -A
git commit --quiet -m "docs: sync wiki from the repository"
git push --quiet
echo "Published $published pages to $REPO"
