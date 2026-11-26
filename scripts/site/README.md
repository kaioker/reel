# Website (docs/ → GitHub Pages)

The site is `docs/index.html` with `docs/assets/` (styles, script, screenshots, clips). GitHub Pages serves
the `docs/` folder of `main` at https://kaioker.github.io/reel/.

## Regenerating the pictures and clips

Everything comes from Reel itself, playing a demo playlist of local video files (`REEL_LIBRARY=<demo.json>`),
with its window on a chosen display (`REEL_SCREEN=<part of the display's name>`).

- **Screenshots** — `REEL_PLAY=first REEL_SHOT=panel,<width>` (add `lists` for the playlists list), then
  `screencapture -l <window id>` (keeps the window's shadow; `-o` leaves it out).
- **Animation clips** — `REEL_DEMO=slide|drop|scrub` plays a scene that ends as it began, so it loops.
  Record it with `record-window.swift` (only Reel's windows, never the desktop):
  `swiftc -O scripts/site/record-window.swift -o .build/record-window`, then
  `.build/record-window <pid> <seconds> <frames-folder> 30 --screen`, crop to the area the window used, and
  encode with ffmpeg (H.264, the page's `--tint` colour behind the transparent corners) plus a first-frame poster.
  The clips play like GIFs (automatically, silently, looping) at a tenth of a GIF's size.
- **Right-click menus** — `REEL_MENUS_TEST=<folder>` writes `menu-video.png` and `menu-track.png`.
- **The peeking creature** — `cutout.swift` cuts it from a flat-background photo:
  `.build/cutout <photo.png> docs/assets/creature-peek.png 900`.
- **The link-preview card** — `og-card.html`, rendered by `render-card.swift`:
  `.build/render-card scripts/site/og-card.html docs/assets/og-card.png 1200 630`.

## The logo lockup

Drawn as SVG (`#lockup` in `index.html`) so the text lines up with the icon exactly: the icon is 100 units
tall, Roboto Slab's cap height is 0.7109 em, so a font size of 140.65 puts the capitals' tops on the icon's
top edge and the baseline (y = 100) on its bottom edge. `overflow: visible` lets the "y" hang below.
