#!/bin/zsh
# Builds a new version of Reel and publishes it as the latest GitHub release.
#   ./release.sh            → builds vYY.WW.NN, commits VERSION, tags, pushes, uploads Reel.zip
# Source changes must be committed first (only VERSION may be uncommitted).
set -e
cd "$(dirname "$0")"
GH=$(command -v gh || echo /opt/homebrew/bin/gh)

if [[ -n "$(git status --porcelain | grep -v ' VERSION$')" ]]; then
  echo "Commit your changes first (git status shows uncommitted files)."; exit 1
fi

./build.sh
VER=$(cat VERSION)
TAG="v$VER"

OUT=".build/release-zip"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent Reel.app "$OUT/Reel.zip"
rm -rf Reel.app   # the zip is what ships; don't leave a second copy of Reel lying around

git add VERSION
git commit -q -m "Release $TAG" -m "Reel was designed and directed by kaioker and built by Claude, Anthropic's AI."
git tag "$TAG"
git push -q
git push -q origin "$TAG"

"$GH" release create "$TAG" "$OUT/Reel.zip" --title "Reel $TAG" --latest \
  --notes "Install or update: \`./install.sh\` (or download Reel.zip, unzip, and drag Reel.app to Applications)."
echo "Published Reel $TAG"
