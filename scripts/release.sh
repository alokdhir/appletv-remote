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

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "release: tag $VERSION already exists" >&2
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

# ── Tag + push ────────────────────────────────────────────────────────────
echo
echo "==> Tagging and pushing $VERSION"
git tag -a "$VERSION" -m "Release $VERSION"
git push origin "$VERSION"

# ── GitHub release ────────────────────────────────────────────────────────
echo
echo "==> Creating GitHub release $VERSION"
if [[ $# -gt 0 ]]; then
    # Pass any remaining args (e.g. -F notes.md or a literal note string) through to gh.
    gh release create "$VERSION" "$DMG_PATH" --title "$VERSION" "$@"
else
    gh release create "$VERSION" "$DMG_PATH" --title "$VERSION" --generate-notes
fi

echo
echo "✓ Released $VERSION"
gh release view "$VERSION" --web 2>/dev/null || true
