#!/bin/zsh
# Builds Reel.app next to this script. Usage: ./build.sh [--install]  (--install copies it to /Applications)
#
# Version: vYY.WW.NN — ISO year . ISO week of the year . build number that week.
# NN goes up on every successful build (no matter how small) and resets to 01 each new week.
# The last version is kept in ./VERSION (without the leading "v").
set -e
cd "$(dirname "$0")"
swift build -c release

YW=$(date +%g.%V)
LAST=$(cat VERSION 2>/dev/null || true)
if [[ "$LAST" == "$YW".* ]]; then N=$(( 10#${LAST##*.} + 1 )); else N=1; fi
VER="$YW.$(printf %02d $N)"
echo "$VER" > VERSION
APP="Reel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Reel "$APP/Contents/MacOS/Reel"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

# Bundled ffmpeg (transparent WebM + converting videos macOS can't decode) — so nothing needs installing.
# Built once from FFmpeg's official source and cached in .deps/ (see scripts/build-ffmpeg.sh).
if [[ ! -x .deps/ffmpeg-bin/ffmpeg ]]; then
  ./scripts/build-ffmpeg.sh || echo "⚠︎ Couldn't build the bundled ffmpeg — Reel will use Homebrew's if present."
fi
if [[ -x .deps/ffmpeg-bin/ffmpeg ]]; then
  mkdir -p "$APP/Contents/Helpers"
  cp .deps/ffmpeg-bin/ffmpeg "$APP/Contents/Helpers/ffmpeg"
  codesign --force --sign - "$APP/Contents/Helpers/ffmpeg" >/dev/null 2>&1 || true
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Reel</string>
  <key>CFBundleDisplayName</key><string>Reel</string>
  <key>CFBundleIdentifier</key><string>app.reel.player</string>
  <key>CFBundleExecutable</key><string>Reel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Media</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array>
        <string>public.movie</string><string>public.audio</string><string>public.audiovisual-content</string><string>public.folder</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built Reel v$VER  →  $(pwd)/$APP"
if [[ "$1" == "--install" ]]; then
  rm -rf /Applications/Reel.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/Reel.app"
fi
