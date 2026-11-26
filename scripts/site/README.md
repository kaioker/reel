# Website (docs/ → GitHub Pages)

The site is `docs/index.html` with `docs/assets/` (styles, script, screenshots, clips). GitHub Pages serves
the `docs/` folder of `main` at https://kaioker.github.io/reel/.

## Regenerating the pictures and clips

Everything comes from Reel itself, playing a demo playlist of local video files (`REEL_LIBRARY=<demo.json>`),
with its window on a chosen display (`REEL_SCREEN=<part of the display's name>`).

- **Screenshots** — `REEL_PLAY=first REEL_SHOT=panel,<width>` (add `lists` for the playlists list), then
  `screencapture -l <window id>` (keeps the window's shadow; `-o` leaves it out).
- **Animation clips** — `REEL_DEMO=hero|slide|drop|scrub` (`REEL_DEMO_TRACK` picks the starting track) plays a
  scene; record it with `record-window.swift` (only Reel's windows, never the desktop):
  `.build/record-window <pid> <seconds> <frames-folder> 30 [--screen]`, then
  `scripts/site/encode-clip.sh <frames> docs/assets/<name> [crop] [last] [first]`, which writes transparent
  `.mov` (HEVC with alpha, for Safari) and `.webm` (VP9 with alpha, for everything else) plus a transparent
  `.png` poster. `site.js` picks the right one per browser and plays clips only while they're on screen.
  Use well-lit scenes (Crystal Cave, First Snow, Moonlit Stage) so the creature's cool-white fur reads as white.
- **Right-click menus** — `REEL_MENUS_TEST=<folder>` writes `menu-video.png` and `menu-track.png`.
- **The peeking creature** — `cutout.swift` cuts it from a flat-background photo, then `grade.swift` relights
  it so the chest fur is the cool white it really is (dim warm light made it grey), lifting the dark fur only a little:
  `.build/cutout <photo.png> peek.png 900 && .build/grade peek.png docs/assets/creature-peek.png`.
- **The link-preview card** — `og-card.html`, rendered by `render-card.swift`:
  `.build/render-card scripts/site/og-card.html docs/assets/og-card.png 1200 630`.

## The logo lockup

Drawn as SVG (`#lockup` in `index.html`) so the text lines up with the icon exactly: the icon is 100 units
tall, Roboto Slab's cap height is 0.7109 em, so a font size of 140.65 puts the capitals' tops on the icon's
top edge and the baseline (y = 100) on its bottom edge. `overflow: visible` lets the "y" hang below.

## Publishing

After changing anything in `docs/assets/`, run `scripts/site/stamp-assets.sh` before committing. It stamps each
`assets/…` link in the page with `?v=` and a hash of the file, so a browser fetches the page, its stylesheet and
its pictures as a matching set. GitHub Pages lets browsers keep each file for 10 minutes, so without the stamp a
reload just after publishing can show the new page with the old stylesheet.

To check the live page in Safari's engine at any width:
`.build/render-card https://kaioker.github.io/reel/ page.png <width> 0` (height 0 renders the whole page).
