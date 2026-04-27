#!/bin/bash
set -euo pipefail

APP_SRC="AppleTVRemote.app"
CLI_SRC="atv"
APP_DEST="/Applications/AppleTVRemote.app"
CLI_DEST="/usr/local/bin/atv"

# Verify we're running from the right directory
if [[ ! -d "$APP_SRC" || ! -f "$CLI_SRC" ]]; then
    echo "Error: run install.sh from the same directory as AppleTVRemote.app and atv."
    exit 1
fi

echo "Installing AppleTVRemote..."

# Stop the running app if present
if pgrep -x AppleTVRemote > /dev/null 2>&1; then
    echo "  Stopping running AppleTVRemote..."
    pkill -x AppleTVRemote
    sleep 1
fi

# Install app
echo "  Copying AppleTVRemote.app → /Applications/"
cp -rf "$APP_SRC" "$APP_DEST"

# Install CLI — /usr/local/bin may not exist on a fresh macOS install
if [[ ! -d /usr/local/bin ]]; then
    echo "  Creating /usr/local/bin..."
    sudo mkdir -p /usr/local/bin
fi

echo "  Copying atv → $CLI_DEST"
if [[ -w /usr/local/bin ]]; then
    cp -f "$CLI_SRC" "$CLI_DEST"
else
    sudo cp -f "$CLI_SRC" "$CLI_DEST"
fi

echo ""
echo "Done. Launch AppleTVRemote from /Applications, or use 'atv' from the terminal."
