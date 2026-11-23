# Reel

A tiny, QuickTime-style video player for macOS that stays on top — with playlists, per-track loop, and Liquid Glass.

- The video fills the whole window (no title bar); controls appear only while the mouse moves
- Shrinks far smaller than most players and keeps the video's shape; park it in a screen corner and it stays there
- Always on top by default (⌘T), so it doesn't slide behind other apps
- Collapsible playlist beside the video, multiple playlists, export/import as `.json`
- Plays video & audio files, direct links, HLS, YouTube videos and playlists, Bilibili, and WebM
  (transparent WebM plays over Liquid Glass when `ffmpeg` is installed)

## Install

Needs the GitHub CLI (`brew install gh`, then `gh auth login`):

```sh
./install.sh
```

Downloads the newest release and puts `Reel.app` in `/Applications`. After that, Reel checks for updates on
launch and offers to install them (or use Reel → Check for Updates…).
Or grab `Reel.zip` from the [Releases](../../releases) page, unzip it, and drag `Reel.app` to Applications.

## Build from source

Requires macOS 13+ and the Swift toolchain (Xcode or the Command Line Tools).

```sh
./build.sh            # builds Reel.app here
./build.sh --install  # …and copies it to /Applications
./release.sh          # builds and publishes a new GitHub release (commit changes first)
```

## Versions

`vYY.WW.NN` — ISO year, ISO week of the year, and the build number that week.
`NN` goes up on every build, no matter how small, and starts again at `01` each week (e.g. `v26.51.12`).

## Controls

| | |
|---|---|
| Click video | Play / pause (works even when Reel isn't focused) |
| Drag video | Move the window |
| Right-drag ← → / ↑ ↓ | Seek / volume (two-finger swipe or mouse wheel too) |
| Right-click | Icon menu |
| Space · ← → · ↑ ↓ | Play/pause · skip 10 s · previous/next track |
| L · M · F | Loop track · mute · full screen |
| ⌘P or the blue circle | Show / hide the playlist |
| ⌘V | Add every link on the clipboard |
| ⌘T · ⌘0 | Always on top · actual size |

In the playlist: click a track to play, double-click a title to rename, right-click for play next / skip / more.
Help → Reel Help (⌘?) has the full list.
