#!/bin/zsh
# Builds Reel.app next to this script. Usage: ./build.sh [--install]  (--install copies it to /Applications)
#
# Version: vYY.WW.NN — ISO year . ISO week of the year . build number that week.
# NN goes up on every successful build (no matter how small) and resets to 01 each new week.
# The last version is kept in ./VERSION (without the leading "v").
set -e
cd "$(dirname "$0")"
# FFmpeg's decoding libraries for the in-app decoder (built once, cached in .deps/)
./scripts/build-ffmpeg-libs.sh      # no-op unless the libraries are missing or their configuration changed
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
# In-app decoder libraries → Contents/Frameworks (separate, replaceable files, as the LGPL asks)
mkdir -p "$APP/Contents/Frameworks"
for lib in .deps/ffmpeg-shared/lib/lib*.dylib; do
  [[ -L "$lib" ]] && continue
  name=$(otool -D "$lib" | tail -1); name=${name##*/}      # the name the app looks it up by (libavcodec.63.dylib)
  cp "$lib" "$APP/Contents/Frameworks/$name"
done
# drop the development-only library path baked in by Package.swift
install_name_tool -delete_rpath "$PWD/.deps/ffmpeg-shared/lib" "$APP/Contents/MacOS/Reel" 2>/dev/null || true
for lib in "$APP/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$lib" >/dev/null 2>&1 || true; done
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Design/ReelPlaylist.icns "$APP/Contents/Resources/ReelPlaylist.icns" 2>/dev/null || true   # .reel file icon
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"          # full license texts (LGPL, libvpx BSD + patent grant)

# Bundled ffmpeg (transparent WebM + converting videos macOS can't decode) — so nothing needs installing.
# Built once from FFmpeg's official source and cached in .deps/ (see scripts/build-ffmpeg.sh).
./scripts/build-ffmpeg.sh      # no-op unless it's missing or FFmpeg / libvpx changed
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
    <dict>
      <key>CFBundleTypeName</key><string>Reel Playlist</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.reel.reel-playlist</string></array>
      <key>CFBundleTypeIconFile</key><string>ReelPlaylist</string>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key><array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.matroska.mkv</string>
      <key>UTTypeDescription</key><string>Matroska video</string>
      <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mkv</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>org.webmproject.webm</string>
      <key>UTTypeDescription</key><string>WebM video</string>
      <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>webm</string></array></dict>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key><array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.reel.reel-playlist</string>
      <key>UTTypeDescription</key><string>Reel Playlist</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeIconFile</key><string>ReelPlaylist</string>
      <key>UTTypeTagSpecification</key><dict>
        <key>public.filename-extension</key><array><string>reel</string></array>
        <key>public.mime-type</key><array><string>application/x-reel-playlist</string></array>
      </dict>
    </dict>
  </array>
</dict></plist>
PLIST
# Ad-hoc signatures are normally pinned to this exact build's hash, so macOS forgets the Accessibility
# permission (hover hotkeys) after every update even though Settings still shows Reel switched on.
# Naming the bundle identifier as the requirement lets the permission carry over to new builds.
codesign --force --sign - -r='designated => identifier "app.reel.player"' "$APP" >/dev/null 2>&1 || true
echo "Built Reel v$VER  →  $(pwd)/$APP"
# Keep macOS from listing this build as another installed Reel (Open With, default apps, Spotlight)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
if [[ "$1" == "--install" ]]; then
  rm -rf /Applications/Reel.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/Reel.app"
  rm -rf "$APP"   # one copy only: the installed one
fi
