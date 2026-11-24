#!/bin/zsh
# Installs (or updates to) the newest Reel release in /Applications.
#   curl -fsSL https://raw.githubusercontent.com/kaioker/reel/main/install.sh | zsh
set -e
URL="https://github.com/kaioker/reel/releases/latest/download/Reel.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Reel…"
curl -fL --progress-bar -o "$TMP/Reel.zip" "$URL"

pkill -x Reel 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Reel.app
ditto -x -k "$TMP/Reel.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Reel.app 2>/dev/null || true   # skip the "unidentified developer" prompt
VERSION=$(defaults read /Applications/Reel.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "")
echo "Installed Reel ${VERSION:+v$VERSION }in /Applications"
open /Applications/Reel.app
