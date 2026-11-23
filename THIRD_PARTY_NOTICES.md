# Third-party software in Reel

Reel.app includes a small build of **FFmpeg** at `Reel.app/Contents/Helpers/ffmpeg`, used to play
transparent WebM videos and to convert videos macOS can't decode. It runs as a separate program.

## FFmpeg
- Version 9.0.2, https://ffmpeg.org
- License: GNU Lesser General Public License v2.1 or later (LGPL). This build enables no GPL or
  non-free components.
- Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz — built with the exact options in
  [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh), which rebuilds it from that source. You may replace
  `Contents/Helpers/ffmpeg` with your own build.

## libvpx (statically linked into the bundled ffmpeg)
- The WebM project, https://chromium.googlesource.com/webm/libvpx
- License: BSD 3-Clause. Copyright (c) 2010, The WebM Project authors. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted
  provided that the conditions of the BSD 3-Clause license are met.
