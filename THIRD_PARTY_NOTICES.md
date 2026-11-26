# Third-party software in Reel

Reel.app includes **FFmpeg** in two forms:

- **Decoding libraries** in `Reel.app/Contents/Frameworks` (`libavformat`, `libavcodec`, `libavutil`,
  `libswscale`, `libswresample`) — Reel's in-app decoder uses them to play transparent WebM, videos
  macOS can't decode and live streams (DASH, RTSP, RTMP, UDP / RTP, MPEG-TS), straight away. They're separate, dynamically linked files you may replace with your
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
- `libavformat` reads DASH manifests with **libxml2**, the copy that's part of macOS (`/usr/lib/libxml2.2.dylib`);
  Reel doesn't ship one.

## libvpx (statically linked into the bundled ffmpeg and libavcodec)
- Version 1.17.0, the WebM project, https://chromium.googlesource.com/webm/libvpx
- Source: https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz (SHA-256 checked), built
  for macOS 13 and later by [`scripts/build-libvpx.sh`](scripts/build-libvpx.sh).
- License: BSD 3-Clause, with an additional patent grant — both reproduced in full below and in
  `licenses/` (also inside Reel.app, next to this file).

```
Copyright (c) 2010, The WebM Project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google, nor the WebM Project, nor the names
    of its contributors may be used to endorse or promote products
    derived from this software without specific prior written
    permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

```
Additional IP Rights Grant (Patents)
------------------------------------

"These implementations" means the copyrightable works that implement the WebM
codecs distributed by Google as part of the WebM Project.

Google hereby grants to you a perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable (except as stated in this section) patent license to
make, have made, use, offer to sell, sell, import, transfer, and otherwise
run, modify and propagate the contents of these implementations of WebM, where
such license applies only to those patent claims, both currently owned by
Google and acquired in the future, licensable by Google that are necessarily
infringed by these implementations of WebM. This grant does not include claims
that would be infringed only as a consequence of further modification of these
implementations. If you or your agent or exclusive licensee institute or order
or agree to the institution of patent litigation or any other patent
enforcement activity against any entity (including a cross-claim or
counterclaim in a lawsuit) alleging that any of these implementations of WebM
or any code incorporated within any of these implementations of WebM
constitute direct or contributory patent infringement, or inducement of
patent infringement, then any patent rights granted to you under this License
for these implementations of WebM shall terminate as of the date such
litigation is filed.
```

## License texts
The full GNU LGPL v2.1 (FFmpeg) is in `licenses/FFmpeg-LGPL-2.1.txt`; libvpx's license and patent grant are
in `licenses/libvpx-LICENSE.txt` and `licenses/libvpx-PATENTS.txt`. Reel.app carries the same files in
`Contents/Resources/licenses`.
