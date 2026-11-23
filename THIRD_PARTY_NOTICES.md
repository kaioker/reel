# Third-party software in Reel

Reel.app includes **FFmpeg** in two forms:

- **Decoding libraries** in `Reel.app/Contents/Frameworks` (`libavformat`, `libavcodec`, `libavutil`,
  `libswscale`, `libswresample`) — Reel's in-app decoder uses them to play transparent WebM and videos
  macOS can't decode, straight away. They're separate, dynamically linked files you may replace with your
  own builds of the same versions (built by [`scripts/build-ffmpeg-libs.sh`](scripts/build-ffmpeg-libs.sh)).
- A small **`ffmpeg` program** at `Reel.app/Contents/Helpers/ffmpeg`, used only as a last resort to
  convert a video the in-app decoder can't handle. It runs as a separate program
  (built by [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh)).

## FFmpeg
- Version 9.0.2, https://ffmpeg.org
- License: GNU Lesser General Public License v2.1 or later (LGPL). This build enables no GPL or
  non-free components.
- Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz — built with the exact options in the two scripts
  above, which rebuild everything from that source.

## libvpx (statically linked into the bundled ffmpeg and libavcodec)
- The WebM project, https://chromium.googlesource.com/webm/libvpx
- License: BSD 3-Clause. Copyright (c) 2010, The WebM Project authors. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted
  provided that the conditions of the BSD 3-Clause license are met.
