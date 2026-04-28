#!/usr/bin/env bash
#
# Cut a GitHub release.
#
#   scripts/release.sh v1.0.0                       # full release
#   scripts/release.sh v1.0.0 "release notes here"  # with notes
#   scripts/release.sh v1.0.0 -F notes.md           # notes from file
#
# What it does:
#   1. Sanity-checks the working tree is clean and we're on main.
#   2. Tags the current commit with the supplied version.
#   3. Builds the signed + notarized DMG via build-dmg.sh.
#   4. Pushes the tag.
#   5. Creates a GitHub release attaching the DMG.
#
# Requires: clean working tree, push access, `gh` CLI authenticated.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: scripts/release.sh <version> [release-notes...]" >&2
    echo "       version must look like vX.Y.Z (e.g. v1.0.0)" >&2
    exit 2
fi

VERSION="$1"
shift

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "release: version must be vX.Y.Z (got '$VERSION')" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Pre-flight ────────────────────────────────────────────────────────────
echo "==> Pre-flight checks"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "release: working tree is dirty — commit or stash first" >&2
    git status --short >&2
    exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "main" ]]; then
    echo "release: not on main (on '$current_branch'). Switch first or override at your peril." >&2
    exit 1
fi

# Check specifically for an existing tag — `git rev-parse "$VERSION"` would
# also resolve a same-named branch / commit-ish, falsely reporting "exists".
if git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
    echo "release: tag $VERSION already exists locally" >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "release: tag $VERSION already exists on origin" >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "release: gh CLI not found — install with 'brew install gh' and 'gh auth login'" >&2
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────
# Strip leading 'v' for the human-readable VERSION so the DMG filename is clean.
echo
echo "==> Building DMG (this includes notarization, ~5 min)"
VERSION="${VERSION#v}" "$REPO_ROOT/scripts/build-dmg.sh"

DMG_PATH="$REPO_ROOT/dist/AppleTVRemote-${VERSION#v}.dmg"
[[ -f "$DMG_PATH" ]] || { echo "release: expected DMG not found at $DMG_PATH" >&2; exit 1; }

# ── Tag locally ───────────────────────────────────────────────────────────
echo
echo "==> Tagging $VERSION (local)"
git tag -a "$VERSION" -m "Release $VERSION"

# ── GitHub release ────────────────────────────────────────────────────────
# Order is deliberate: create the release + upload the DMG BEFORE pushing
# the tag. If the upload or release-create fails, we don't end up with a
# tag on origin pointing at no release. `gh release create` works on a
# local-only tag and pushes it as part of asset upload.
echo
echo "==> Creating GitHub release $VERSION + uploading DMG"
release_args=("$VERSION" "$DMG_PATH" --title "$VERSION")
if [[ $# -gt 0 ]]; then
    release_args+=("$@")  # caller-provided notes/flags
else
    release_args+=(--generate-notes)
fi

if ! gh release create "${release_args[@]}"; then
    echo "release: gh release create failed — leaving local tag in place" >&2
    echo "release: delete it with 'git tag -d $VERSION' if you want to retry" >&2
    exit 1
fi

# ── Push tag (gh already pushed it as part of release create, but make
#    sure local refs are visible explicitly so 'git pull' on other clones
#    sees the tag without --tags). Idempotent.
echo
echo "==> Pushing tag $VERSION to origin"
git push origin "$VERSION"

echo
echo "✓ Released $VERSION"
gh release view "$VERSION" --web 2>/dev/null || true
