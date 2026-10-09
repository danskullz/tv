# Third-party media components: versions, licenses, LGPL compliance

Marquee is closed source. Its playback stack (libmpv + FFmpeg and friends) is built by
[`scripts/build-mpv.sh`](../scripts/build-mpv.sh) from pinned, SHA-256-verified, **unmodified** upstream
tarballs and shipped as **separate dynamic libraries** in `Marquee.app/Contents/Frameworks`. This file is the
source of truth for what is shipped and why that is license-compliant. `scripts/bundle.sh` copies it into the app
(`Contents/Resources/Licenses/THIRD-PARTY.md`) next to the full license texts.

## Components

| Component | Version | License as built | Notes |
|---|---|---|---|
| mpv (libmpv only) | 0.41.0 | **LGPL-2.1-or-later** | Built with `-Dgpl=false` (the default build is GPL-2.0+). `-Dcplayer=false`, no Lua/JS. Client API headers are ISC. |
| FFmpeg (libavcodec, libavformat, libavutil, libavfilter, libswscale, libswresample) | 8.1.3 | **LGPL-2.1-or-later** | Configured without `--enable-gpl`, `--enable-version3`, `--enable-nonfree`; `--disable-everything` plus an allowlist (see below). |
| libplacebo | 7.360.1 | LGPL-2.1-or-later | Shared library. Vulkan/OpenGL/D3D11/lcms/dovi disabled; supplies colour-management and tone-mapping shader logic to mpv. |
| dav1d | 1.5.4 | BSD-2-Clause | AV1 software decoder (Intel Macs have no AV1 hardware decode; Apple's only exists on M3+). |
| libass | 0.17.5 | ISC | CoreText font provider, no fontconfig. |
| FreeType | 2.14.3 | FreeType License (FTL, BSD-style) | We choose the FTL, not the GPLv2 alternative. **Attribution required** (below). |
| HarfBuzz | 14.6.0 | "Old MIT" | |
| FriBidi | 1.0.17 | LGPL-2.1-or-later | Shared library. |

Build-time only (never shipped): Jinja2 3.1.6 and MarkupSafe 3.0.3 (BSD-3, libplacebo's GLSL preprocessor), fast_float 8.3.1
(Apache-2.0/MIT/BSL, header-only, compiled into libplacebo's string parsing), Vulkan-Headers 1.4.365 (Apache-2.0/MIT,
headers only; libplacebo's public headers include them even though its Vulkan backend is off).

System libraries linked dynamically from macOS (not redistributed): `libSystem`, `libz`, `libiconv`, `libc++`,
and the Apple frameworks (VideoToolbox, CoreVideo, CoreAudio, AudioToolbox, AVFoundation, OpenGL, …).

No Homebrew library is ever linked. Homebrew is used for **build tools only** (meson, ninja, pkg-config, nasm), and
`build-mpv.sh` fails if any produced dylib references a path other than `/usr/lib`, `/System` or `@rpath`.

## What makes it LGPL (and how to check)

* **mpv:** `-Dgpl=false`. `mpv_get_property_string(h, "mpv-configuration")` contains `-Dgpl=false`; the unit test
  `libraryIsLGPLBuildWithMatchingAPIVersion` asserts it, and `build-mpv.sh` re-checks after every build.
* **FFmpeg:** `avutil_license()` (and the five other libraries') return `LGPL version 2.1 or later`;
  `avutil_configuration()` contains none of `--enable-gpl`, `--enable-version3`, `--enable-nonfree`. FFmpeg's
  configure refuses to enable any GPL-only component without `--enable-gpl`, so the allowlist cannot smuggle one in.
* mpv's macOS glue (`osdep/mac/*.swift`, the `cocoa` feature that unlocks the zero-copy VideoToolbox/OpenGL path) is part of
  mpv itself and LGPL like the rest; it links the OS Swift runtime (`/usr/lib/swift`), nothing is bundled for it.
* **Explicitly absent (GPL or non-free):** x264, x265, libfdk-aac, rubberband, libpostproc, zimg, VapourSynth,
  libbluray/libdvdnav (GPL builds), `--enable-gpl` filters, any external encoder.
* Allowed LGPL-compatible externals: dav1d (BSD-2) only.

`build-mpv.sh` writes the exact configure lines to `Vendor/mpv/BUILD-INFO.txt`.

## Obligations and how Marquee meets them

1. **Dynamic linking, user-replaceable libraries (LGPL-2.1 §6).** Every LGPL library is its own `.dylib` in
   `Contents/Frameworks`, loaded at run time (`MarqueePlayer` `dlopen`s `libmpv.2.dylib`; it does not link it).
   A user can build the same libraries from the sources below, with different flags or fixes, and drop them in.
   Install names are `@rpath/…` with an `@loader_path` rpath, so replacements need no relinking of Marquee.
   * *Code signing caveat:* a replaced dylib is not signed by our Developer ID. Under the hardened runtime this is
     refused unless library validation is relaxed. **Decision needed before the first notarized release:** either ship
     `com.apple.security.cs.disable-library-validation` (simplest, and what lets the LGPL swap actually work) or
     document `codesign --force --sign - Marquee.app/Contents/Frameworks/*.dylib && codesign --force --sign - Marquee.app`
     for users who replace libraries.
2. **License notices.** Full texts for each component are copied to `Contents/Resources/Licenses/<name>/`, and the app
   must show an "Acknowledgements" screen listing them (Settings → About; to do in the UI work).
   * FreeType credit line (FTL §2), to include in that screen and the docs:
     *"Portions of this software are copyright © 2000–2026 The FreeType Project (www.freetype.org). All rights reserved."*
3. **Source availability (LGPL §6(a)/(c)).** Marquee ships the libraries **unmodified** (the build applies no patches).
   The corresponding source is the upstream tarball at the URL in `build-mpv.sh`, whose SHA-256 is pinned there; the
   release page links the exact `build-mpv.sh` used. For durability, mirror the eight tarballs as assets of each
   GitHub Release (or keep a written offer valid for at least three years) before the public release.
4. **Reverse engineering for debugging (LGPL §6).** The Marquee EULA/terms must not forbid reverse engineering *of the
   LGPL libraries' interaction with Marquee* when done to debug modifications of those libraries.
5. **No GPL contamination.** Anything that would require `--enable-gpl` / `-Dgpl=true` is out of bounds (see above); the
   build script and the unit test fail loudly if it creeps in.

## Bumping a component

1. Change `*_VER`, `*_URL`, `*_SHA` in `scripts/build-mpv.sh` (`shasum -a 256 <tarball>`). The CI cache key is the hash
   of that script, so CI rebuilds automatically.
2. Re-read the upstream release notes for license changes (especially FFmpeg: new components marked GPL, mpv: options
   that become GPL-only) and update this file.
3. `scripts/build-mpv.sh` (see the build-time table in the PR/report; roughly 15-25 min for both arches on an 8-core Intel Mac,
   instant when `~/Library/Caches/Marquee/deps/mpv-out/<key>` exists) and run `swift test`.

The tarball checksums were recorded on first download (trust on first use) from the official sources: ffmpeg.org,
downloads.videolan.org, download.savannah.gnu.org, and the projects' GitHub releases/tags. libplacebo's canonical host
(code.videolan.org) sits behind a bot check, so its GitHub mirror's tag archive is used.

## FFmpeg feature allowlist (size and attack-surface minimisation)

* Decoders: H.264, HEVC, AV1 (dav1d), VP8/9, MPEG-1/2/4, MS-MPEG4, VC-1/WMV, Theora, MJPEG, PNG, GIF, ProRes; AAC,
  AC-3/E-AC-3, DTS, TrueHD/MLP, FLAC, Opus, Vorbis, MP1/2/3, ALAC, WMA, APE, TAK, WavPack, AMR, PCM family; subtitles:
  ASS/SSA, SRT, WebVTT, mov_text, DVD/DVB/PGS bitmap subs, MicroDVD, SubViewer, SAMI, RealText, JACOsub, PJS, STL,
  VPlayer, CEA-608.
* Demuxers: Matroska/WebM, MP4/MOV, MPEG-TS/PS, AVI, ASF, FLV, Ogg, FLAC, MP3, AAC, AC-3/E-AC-3, DTS(-HD), TrueHD,
  WAV, AIFF, APE, WavPack, TAK, AMR, HLS, IVF, raw H.264/HEVC, RealMedia, text subtitle formats, image pipes.
* Encoders: PNG and MJPEG only (screenshots).
* Protocols: `file`, `http`, `tcp`, `pipe`, `data`, `cache`. No TLS, no RTMP/RTSP/UDP/etc. Marquee feeds mpv from its
  own loopback range server.
* Hardware: VideoToolbox decode (H.264, HEVC, VP9, AV1, MPEG-1/2/4, H.263, ProRes).
* Filters: graph plumbing, resample/format/volume/pan/channelmap/tempo/compressor/loudnorm/dynaudnorm/equalizer,
  scale/crop/pad/flip/rotate/yadif/bwdif/fps.
