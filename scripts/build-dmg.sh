#!/usr/bin/env bash
#
# Build a distributable AppleTVRemote DMG.
#
# Usage:
#   scripts/build-dmg.sh                       # auto-detected identity + profile
#   SIGN_IDENTITY=- scripts/build-dmg.sh       # force ad-hoc (no Developer ID)
#   NOTARIZE_PROFILE= scripts/build-dmg.sh     # skip notarization
#
# Env vars (all optional — sane defaults from the keychain):
#   SIGN_IDENTITY       Codesign identity. Defaults to the first valid
#                       "Developer ID Application" in the keychain. Set to
#                       "-" to force ad-hoc signing (no Developer ID needed,
#                       but Gatekeeper will warn end-users).
#   NOTARIZE_PROFILE    notarytool keychain profile name. Defaults to
#                       "appletv-remote-notarization" if that profile exists,
#                       otherwise empty (skip). Set explicitly to "" to skip.
#                       First-time setup:
#                         xcrun notarytool store-credentials \
#                           appletv-remote-notarization \
#                           --apple-id ... --team-id ... --password ...
#   VERSION             Version string baked into the DMG filename.
#                       Default: today's date (yyyy.mm.dd).
#
# Requires: xcodebuild, swift (Package.swift CLI build), hdiutil, codesign.
#           For notarization: xcrun notarytool, xcrun stapler.

set -euo pipefail

# Auto-detect a Developer ID Application identity if SIGN_IDENTITY isn't set —
# spares us from typing it every release. Falls back to ad-hoc if there isn't one.
auto_sign_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F\" '/Developer ID Application/ {print $2; exit}'
}
SIGN_IDENTITY="${SIGN_IDENTITY:-$(auto_sign_identity)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc, ultimate fallback

# Default the notarytool profile to the conventional name we set up;
# unset NOTARIZE_PROFILE explicitly (NOTARIZE_PROFILE="") to skip notarization.
if [[ -z "${NOTARIZE_PROFILE+x}" ]] && \
   xcrun notarytool history --keychain-profile appletv-remote-notarization >/dev/null 2>&1; then
    NOTARIZE_PROFILE=appletv-remote-notarization
fi
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

VERSION="${VERSION:-$(date +%Y.%m.%d)}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
STAGING="$DIST_DIR/staging"
BUILD_DIR="$DIST_DIR/build"
DMG_NAME="AppleTVRemote-$VERSION"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"

mkdir -p "$DIST_DIR"

echo "==> Configuration"
echo "    Sign identity:    $SIGN_IDENTITY"
echo "    Notarize profile: ${NOTARIZE_PROFILE:-<disabled>}"
echo "    Version:          $VERSION"
echo "    DMG output:       $DMG_PATH"
echo

# ── Build .app (xcodebuild) ────────────────────────────────────────────────
echo "==> Building .app via xcodebuild Release..."
xcodebuild -project "$REPO_ROOT/AppleTVRemote.xcodeproj" \
    -scheme AppleTVRemote \
    -configuration Release \
    SYMROOT="$BUILD_DIR" \
    OBJROOT="$BUILD_DIR/obj" \
    build \
    > "$DIST_DIR/build.log" 2>&1 \
    || { tail -30 "$DIST_DIR/build.log"; exit 1; }

APP_SRC="$BUILD_DIR/Release/AppleTVRemote.app"
[[ -d "$APP_SRC" ]] || { echo "App not built at $APP_SRC"; exit 1; }

# ── Build atv CLI (SPM — xcodebuild scheme is GUI-only) ───────────────────
echo "==> Building atv CLI via swift build -c release..."
(cd "$REPO_ROOT" && swift build -c release 2>&1 | tail -2)
ATV_SRC="$REPO_ROOT/.build/release/atv"
[[ -x "$ATV_SRC" ]] || { echo "atv CLI not built at $ATV_SRC"; exit 1; }

# ── Sign ───────────────────────────────────────────────────────────────────
# `--options runtime` enables Hardened Runtime (required for notarization).
# `--timestamp` adds a secure timestamp (required for notarization).
# Ad-hoc signing ignores `--timestamp` silently — that's fine for testing.
echo "==> Signing .app + atv..."
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP_SRC"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$ATV_SRC"

# ── Stage DMG contents ─────────────────────────────────────────────────────
echo "==> Staging DMG contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_SRC"                      "$STAGING/AppleTVRemote.app"
cp    "$ATV_SRC"                      "$STAGING/atv"
cp    "$REPO_ROOT/scripts/install.sh" "$STAGING/install.sh"
cp    "$REPO_ROOT/scripts/README.txt" "$STAGING/README.txt"
chmod +x "$STAGING/install.sh"
# Drag-target shortcut: dragging the .app onto this symlink installs into /Applications.
ln -sf /Applications "$STAGING/Applications"

# ── Build DMG ──────────────────────────────────────────────────────────────
echo "==> Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "AppleTV Remote" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null

# ── Sign DMG (only meaningful with Developer ID) ──────────────────────────
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "==> Signing DMG..."
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

# ── Notarize + staple ─────────────────────────────────────────────────────
if [[ -n "$NOTARIZE_PROFILE" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "!! Skipping notarization — needs a real Developer ID identity."
    else
        echo "==> Submitting for notarization (5–15 min)..."
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARIZE_PROFILE" \
            --wait
        echo "==> Stapling notarization ticket..."
        xcrun stapler staple "$DMG_PATH"
    fi
fi

# ── Verify ────────────────────────────────────────────────────────────────
echo
echo "==> Verification"
codesign --verify --verbose=2 "$APP_SRC" 2>&1 | sed 's/^/    /'
spctl --assess --type execute --verbose "$APP_SRC" 2>&1 | sed 's/^/    /' || true
if [[ -n "$NOTARIZE_PROFILE" && "$SIGN_IDENTITY" != "-" ]]; then
    spctl --assess --type open --context context:primary-signature \
        --verbose "$DMG_PATH" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "✓ Built: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "  Contents: AppleTVRemote.app, atv, install.sh, README.txt, Applications →"
