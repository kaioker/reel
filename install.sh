#!/bin/zsh
# Installs (or updates to) the newest Reel release in /Applications.
# Needs the GitHub CLI logged in:  brew install gh && gh auth login
set -e
REPO="kaioker/reel"
GH=$(command -v gh || echo /opt/homebrew/bin/gh)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TAG=$("$GH" release view --repo "$REPO" --json tagName --jq .tagName)
echo "Downloading Reel $TAG…"
"$GH" release download "$TAG" --repo "$REPO" --pattern Reel.zip --dir "$TMP"

pkill -x Reel 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Reel.app
ditto -x -k "$TMP/Reel.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Reel.app 2>/dev/null || true   # skip the "unidentified developer" prompt
echo "Installed Reel $TAG in /Applications"
open /Applications/Reel.app
