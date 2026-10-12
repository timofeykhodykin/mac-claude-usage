#!/bin/bash
# Releases version X.Y.Z: moves CHANGELOG's "Unreleased" section under the new version,
# writes VERSION, commits, tags vX.Y.Z and pushes. The tag triggers
# .github/workflows/release.yml, which builds the app and publishes the GitHub release.
#
#   ./scripts/release.sh 1.2.0 [extra git commit args, e.g. --trailer "Co-Authored-By: …"]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 X.Y.Z [git commit args]" >&2
    exit 1
fi
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == "main" ]] || fail "not on main"
[[ -z "$(git status --porcelain)" ]] || fail "working tree has uncommitted changes"
git fetch --quiet --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"

CURRENT="$(tr -d '[:space:]' < VERSION)"
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
    || fail "$VERSION is not newer than the current version $CURRENT"

# The Unreleased section must have content: it becomes the release notes.
NOTES="$(awk '/^## /{p = ($2 == "Unreleased"); next} p' CHANGELOG.md | grep -v '^[[:space:]]*$' || true)"
[[ -n "$NOTES" ]] || fail "CHANGELOG.md has nothing under '## Unreleased'"

./scripts/test.sh

echo "$VERSION" > VERSION
awk -v v="$VERSION" -v d="$(date +%Y-%m-%d)" \
    '/^## Unreleased$/ {print; print ""; print "## " v " - " d; next} {print}' \
    CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

git add VERSION CHANGELOG.md
git commit --quiet -m "Release $VERSION" "$@"
git tag -a "$TAG" -m "Claude Usage $VERSION"
git push --atomic origin main "$TAG"
echo "Pushed $TAG. Follow the build: gh run watch \$(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
