#!/usr/bin/env bash
#
# Builds an LGPL, universal (arm64 + x86_64), dynamically linked libmpv and all of its
# dependencies from pinned, SHA-256-verified source tarballs, and stages the result in
# Vendor/mpv/ (git-ignored).
#
#   scripts/build-mpv.sh                 # build everything for arm64 + x86_64, lipo, stage into Vendor/mpv
#                                        # (instant when the finished output for this script is cached)
#   scripts/build-mpv.sh --print-key     # print the cache key (versions + script hash) and exit
#   scripts/build-mpv.sh --force         # ignore the finished-output cache and Vendor/mpv, re-stage (stamps still apply)
#   scripts/build-mpv.sh --arch x86_64   # build one arch only (no lipo; stages that arch)
#   scripts/build-mpv.sh --only ffmpeg   # (re)build a single component for the chosen arches
#   scripts/build-mpv.sh --clean         # delete the cache and Vendor/mpv, then build
#   scripts/build-mpv.sh --verify-only   # re-run the LGPL / linkage checks on Vendor/mpv
#
# Idempotent and resumable: each (component, arch) gets a stamp keyed by its version, source
# SHA-256 and configuration; a finished component is skipped on the next run, an interrupted one
# is rebuilt from a clean build dir. Changing a flag in this file rebuilds just that component.
#
# Environment:
#   MARQUEE_DEPS_CACHE  cache root shared with build-libtorrent.sh (default ~/Library/Caches/Marquee/deps).
#                       Sources/build trees live in <root>/mpv, finished output in <root>/mpv-out/<key>
#                       (CI caches that directory). Safe to share between worktrees.
#   JOBS                parallel jobs (default: logical CPU count)
#   MPV_STAGE_DIR       output directory (default <repo>/Vendor/mpv)
#
# Host requirements (BUILD TOOLS ONLY, never linked): Xcode (or CLT), meson, ninja, pkg-config,
# nasm, python3. e.g. `brew install meson ninja pkg-config nasm`.
# Nothing from Homebrew is ever linked; PKG_CONFIG_LIBDIR is pinned to our own prefix and the
# verify step fails the build if any dylib references a path outside the system / @rpath.
#
# Licensing: the build is LGPL-only. mpv is configured with -Dgpl=false, FFmpeg without
# --enable-gpl / --enable-version3 / --enable-nonfree. See docs/licenses.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_ROOT="${MARQUEE_DEPS_CACHE:-$HOME/Library/Caches/Marquee/deps}"
CACHE="$DEPS_ROOT/mpv"
STAGE_OUT="${MPV_STAGE_DIR:-$ROOT/Vendor/mpv}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"
DEPLOYMENT_TARGET="15.0"
HOST_ARCH="$(uname -m)"

# ---------------------------------------------------------------------------------------------
# Pinned sources. To bump: change version + sha256 (shasum -a 256 <tarball>), review docs/licenses.md.
# ---------------------------------------------------------------------------------------------
FFMPEG_VER=8.1.3
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz"
FFMPEG_SHA=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3

DAV1D_VER=1.5.4
DAV1D_URL="https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VER/dav1d-$DAV1D_VER.tar.xz"
DAV1D_SHA=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5

FREETYPE_VER=2.14.3
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz"
FREETYPE_SHA=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f

FRIBIDI_VER=1.0.17
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VER/fribidi-$FRIBIDI_VER.tar.xz"
FRIBIDI_SHA=6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2

HARFBUZZ_VER=14.6.0
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VER/harfbuzz-$HARFBUZZ_VER.tar.xz"
HARFBUZZ_SHA=d07a007327277708a2a73ae437887cdbaf282937f6d03ca5467723e9099af586

LIBASS_VER=0.17.5
LIBASS_URL="https://github.com/libass/libass/releases/download/$LIBASS_VER/libass-$LIBASS_VER.tar.xz"
LIBASS_SHA=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc

# libplacebo's canonical host (code.videolan.org) sits behind a bot check, so use the GitHub
# mirror's tag archive. Submodules (glad/jinja/Vulkan headers) are not needed: Vulkan/OpenGL
# backends are disabled (mpv's render API uses its own GL backend; libplacebo supplies colour
# management / tone mapping / dithering shader logic only).
LIBPLACEBO_VER=7.360.1
LIBPLACEBO_URL="https://github.com/haasn/libplacebo/archive/refs/tags/v$LIBPLACEBO_VER.tar.gz"
LIBPLACEBO_SHA=d05fdf90bea2f629eaa2d115e909fd356388ac639e54f77b87a018a6d76224bd

# libplacebo's GLSL preprocessor (build time only, never shipped) is a Python script that needs Jinja2 and
# MarkupSafe; upstream vendors them as git submodules, which release tarballs lack. Pure-Python use.
JINJA_VER=3.1.6
JINJA_URL="https://github.com/pallets/jinja/archive/refs/tags/$JINJA_VER.tar.gz"
JINJA_SHA=2074b22a72caa65474902234b320d73463d6d4c223ee49f4b433495758356337
MARKUPSAFE_VER=3.0.3
MARKUPSAFE_URL="https://github.com/pallets/markupsafe/archive/refs/tags/$MARKUPSAFE_VER.tar.gz"
MARKUPSAFE_SHA=f1d9d06c34515dd3ad210ec769da613057b536d11d6c039183b87757a883a254

FAST_FLOAT_VER=8.3.1   # header-only (MIT/Apache-2.0), another libplacebo submodule
FAST_FLOAT_URL="https://github.com/fastfloat/fast_float/archive/refs/tags/v$FAST_FLOAT_VER.tar.gz"
FAST_FLOAT_SHA=7ff47ad261068517561beb0a7c1d57131f71b8be19bdbac2857c6a517a2eb53c

# Vulkan headers: libplacebo's public headers include <vulkan/vulkan.h> even with Vulkan disabled. Compile-time only.
VULKAN_HEADERS_VER=1.4.365
VULKAN_HEADERS_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$VULKAN_HEADERS_VER.tar.gz"
VULKAN_HEADERS_SHA=ed832b3292cce324ebba6522fd2d3004bf1b797fa49bfbcad0b302ff23d56abc

MPV_VER=0.41.0
MPV_URL="https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VER.tar.gz"
MPV_SHA=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209

# ---------------------------------------------------------------------------------------------
# Configuration (hashed into stamps, so editing a flag triggers a rebuild of that component).
# ---------------------------------------------------------------------------------------------
FFMPEG_DECODERS=(
  # video
  h264 hevc libdav1d vp9 vp8 mpeg2video mpeg1video mpeg4 msmpeg4v1 msmpeg4v2 msmpeg4v3 h263 h263p
  vc1 wmv1 wmv2 wmv3 theora mjpeg png gif prores rawvideo
  # audio
  aac aac_latm ac3 eac3 dca truehd mlp flac opus vorbis mp1 mp1float mp2 mp2float mp3 mp3float
  alac wmav1 wmav2 wmapro wmalossless ape tak wavpack amrnb amrwb adpcm_ima_wav adpcm_ms
  pcm_alaw pcm_mulaw pcm_s8 pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
  pcm_f32le pcm_f32be pcm_f64le pcm_f64be pcm_bluray pcm_dvd
  # subtitles
  ass ssa subrip srt webvtt movtext dvdsub dvbsub pgssub text microdvd subviewer subviewer1 sami
  realtext jacosub pjs stl vplayer ccaption
)
FFMPEG_ENCODERS=(png mjpeg)   # only what screenshots need
FFMPEG_DEMUXERS=(
  matroska mov mpegts mpegps mpegvideo avi asf flv ogg flac mp3 aac ac3 eac3 dts dtshd truehd mlp
  wav aiff ape wv tak amr hls ivf h264 hevc m4v rm srt ass webvtt microdvd sami subviewer
  subviewer1 realtext jacosub mpl2 pjs stl vplayer concat image2 image_png_pipe image_jpeg_pipe
  image_webp_pipe image_bmp_pipe image_gif_pipe pcm_s16le pcm_s16be pcm_s24le pcm_s32le pcm_f32le
  pcm_u8 pcm_alaw pcm_mulaw
)
FFMPEG_PARSERS=(
  h264 hevc av1 vp9 vp8 mpeg4video mpegvideo mpegaudio vc1 h263 aac aac_latm ac3 dca flac opus
  vorbis mlp dvdsub dvbsub png mjpeg gif cook amr tak
)
FFMPEG_PROTOCOLS=(file http tcp pipe data cache)   # no TLS, no other network protocols
FFMPEG_BSFS=(
  h264_mp4toannexb hevc_mp4toannexb aac_adtstoasc extract_extradata vp9_superframe vp9_superframe_split
  av1_frame_split av1_frame_merge dts2pts eac3_core dca_core truehd_core mov2textsub text2movsub null
  pgs_frame_merge mpeg4_unpack_bframes
)
FFMPEG_FILTERS=(
  # graph plumbing
  buffer buffersink abuffer abuffersink null anull format aformat nullsink anullsink
  # audio
  aresample atempo volume pan channelmap channelsplit amix adelay asetrate atrim areverse
  acompressor dynaudnorm loudnorm equalizer highpass lowpass bass treble silenceremove afade
  # video
  scale trim crop pad hflip vflip transpose rotate yadif bwdif setpts setsar setdar fps
)
FFMPEG_HWACCELS=(
  h264_videotoolbox hevc_videotoolbox vp9_videotoolbox av1_videotoolbox mpeg1_videotoolbox
  mpeg2_videotoolbox mpeg4_videotoolbox h263_videotoolbox prores_videotoolbox
)

join_by() { local IFS="$1"; shift; echo "$*"; }

FFMPEG_ARGS=(
  --enable-shared --disable-static --enable-pic --enable-small
  --disable-gpl --disable-nonfree --disable-version3     # LGPL-2.1+ only
  --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-htmlpages
  --disable-manpages --disable-podpages --disable-txtpages
  --disable-avdevice
  --disable-everything
  --enable-avcodec --enable-avformat --enable-avutil --enable-avfilter --enable-swscale --enable-swresample
  "--enable-decoder=$(join_by , "${FFMPEG_DECODERS[@]}")"
  "--enable-encoder=$(join_by , "${FFMPEG_ENCODERS[@]}")"
  "--enable-demuxer=$(join_by , "${FFMPEG_DEMUXERS[@]}")"
  "--enable-parser=$(join_by , "${FFMPEG_PARSERS[@]}")"
  "--enable-protocol=$(join_by , "${FFMPEG_PROTOCOLS[@]}")"
  "--enable-bsf=$(join_by , "${FFMPEG_BSFS[@]}")"
  "--enable-filter=$(join_by , "${FFMPEG_FILTERS[@]}")"
  "--enable-hwaccel=$(join_by , "${FFMPEG_HWACCELS[@]}")"
  --enable-videotoolbox --enable-libdav1d --enable-zlib --enable-iconv --enable-network
)

DAV1D_ARGS=(-Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false -Dbitdepths=8,16)
FREETYPE_ARGS=(-Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled -Dtests=disabled)
FRIBIDI_ARGS=(-Ddocs=false -Dbin=false -Dtests=false)
HARFBUZZ_ARGS=(-Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dpng=disabled
  -Dzlib=disabled -Dicu=disabled -Dfreetype=enabled -Dcoretext=disabled -Draster=disabled
  -Dvector=disabled -Dgpu=disabled -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled
  -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled)
LIBASS_ARGS=(--enable-shared --disable-static --disable-fontconfig --disable-directwrite --enable-coretext
  --disable-libunibreak --disable-require-system-font-provider --disable-test --disable-profile)
LIBPLACEBO_ARGS=(-Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled
  -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled -Ddemos=false
  -Dtests=false -Dbench=false -Dfuzz=false)
MPV_ARGS=(
  -Dgpl=false -Dcplayer=false -Dlibmpv=true -Dbuild-date=false -Dtests=false -Dfuzzers=false
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
  # scripting / optional libs: off (no Lua, no JS, nothing that would pull a GPL or Homebrew lib)
  -Dlua=disabled -Djavascript=disabled -Dcplugins=disabled -Dcdda=disabled -Ddvdnav=disabled -Ddvbin=disabled
  -Dlibbluray=disabled -Dlibarchive=disabled -Dlcms2=disabled -Drubberband=disabled -Duchardet=disabled
  -Dvapoursynth=disabled -Dzimg=disabled -Djpeg=disabled -Dlibavdevice=disabled -Dsdl2-gamepad=disabled
  -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dcaca=disabled -Dsixel=disabled -Diconv=enabled -Dzlib=enabled
  # no X11 / Wayland / Vulkan / DRM / EGL / other platforms
  -Dx11=disabled -Dwayland=disabled -Dxv=disabled -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled
  -Ddrm=disabled -Dgbm=disabled -Degl=disabled -Dvaapi=disabled -Dvdpau=disabled -Dd3d11=disabled
  -Dgl-x11=disabled -Dpipewire=disabled -Dpulse=disabled -Dalsa=disabled -Djack=disabled -Dopenal=disabled
  -Dsndio=disabled -Doss-audio=disabled
  # macOS: libmpv render API only. OpenGL via the render API (plain-gl). The `cocoa` feature (which mpv
  # implements in Swift) is what unlocks gl-cocoa and with it the zero-copy VideoToolbox->OpenGL hwdec,
  # so Swift stays on; mpv's own cocoa-cb layer, media-player and touch-bar glue are not needed.
  -Dgl=enabled -Dplain-gl=enabled -Dcocoa=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled
  -Dswift-build=enabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled -Dmacos-touchbar=disabled
  -Dcoreaudio=enabled -Davfoundation=enabled
)

SCRIPT_HASH="$(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-12)"
KEY="mpv${MPV_VER}-ffmpeg${FFMPEG_VER}-${SCRIPT_HASH}"
OUT="$DEPS_ROOT/mpv-out/$KEY"

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

ARCHES=(arm64 x86_64)
ONLY=""
CLEAN=0
VERIFY_ONLY=0
FORCE=0
FULL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCHES=("$2"); FULL=0; shift 2 ;;
    --only) ONLY="$2"; FULL=0; shift 2 ;;
    --print-key) echo "$KEY"; exit 0 ;;
    --force) FORCE=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$FULL" = 1 ] && [ "$FORCE" = 0 ] && [ "$CLEAN" = 0 ] && [ "$VERIFY_ONLY" = 0 ] && [ -f "$OUT/.complete" ]; then
  log "reusing finished build $KEY"
  mkdir -p "$STAGE_OUT"
  rsync -a --delete "$OUT/" "$STAGE_OUT/"
  rm -f "$STAGE_OUT/.complete"
  log "installed $KEY into $STAGE_OUT"
  exit 0
fi

for t in meson ninja pkg-config nasm python3 curl shasum xcrun lipo install_name_tool otool codesign; do
  command -v "$t" >/dev/null 2>&1 || die "missing build tool: $t (brew install meson ninja pkg-config nasm)"
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun -f clang)"
CLANGXX="$(xcrun -f clang++)"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
unset PKG_CONFIG_PATH CFLAGS CXXFLAGS LDFLAGS CPPFLAGS OBJCFLAGS

DL="$CACHE/downloads"; SRC="$CACHE/src"; STAMPS="$CACHE/stamps"
mkdir -p "$DL" "$SRC" "$STAMPS"

if [ "$CLEAN" = 1 ]; then log "cleaning $CACHE and $STAGE_OUT"; rm -rf "$CACHE" "$STAGE_OUT"; mkdir -p "$DL" "$SRC" "$STAMPS"; fi

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch() { # name version url sha
  local name="$1" ver="$2" url="$3" sha="$4"
  local file="$DL/$name-$ver.${url##*.}"
  [ "${url%.tar.gz}" != "$url" ] && file="$DL/$name-$ver.tar.gz"
  [ "${url%.tar.xz}" != "$url" ] && file="$DL/$name-$ver.tar.xz"
  if [ ! -f "$file" ] || [ "$(sha_of "$file")" != "$sha" ]; then
    log "downloading $name $ver"
    rm -f "$file"
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got; got="$(sha_of "$file")"
  [ "$got" = "$sha" ] || { rm -f "$file"; die "SHA-256 mismatch for $name $ver: expected $sha, got $got"; }
  if [ ! -f "$SRC/$name-$ver/.extracted" ]; then
    rm -rf "$SRC/$name-$ver"; mkdir -p "$SRC/$name-$ver"
    tar -xf "$file" -C "$SRC/$name-$ver" --strip-components=1
    touch "$SRC/$name-$ver/.extracted"
  fi
}

src_of() { echo "$SRC/$1-$2"; }

arch_setup() { # arch -> sets per-arch globals
  A="$1"
  PREFIX="$CACHE/prefix/$A"
  BUILD="$CACHE/build/$A"
  mkdir -p "$PREFIX" "$BUILD"
  case "$A" in
    arm64)  TRIPLE=aarch64-apple-darwin; CPU_FAMILY=aarch64; FF_ARCH=aarch64 ;;
    x86_64) TRIPLE=x86_64-apple-darwin;  CPU_FAMILY=x86_64;  FF_ARCH=x86_64 ;;
    *) die "unsupported arch $A" ;;
  esac
  CROSS=0; [ "$A" != "$HOST_ARCH" ] && CROSS=1
  COMMON_FLAGS="-arch $A -isysroot $SDK -mmacosx-version-min=$DEPLOYMENT_TARGET -O2 -fno-strict-aliasing -I$PREFIX/include"
  LINK_FLAGS="-arch $A -isysroot $SDK -mmacosx-version-min=$DEPLOYMENT_TARGET -L$PREFIX/lib"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH=""
  CROSS_FILE="$BUILD/meson-cross.ini"
  local wrapper=false; [ "$CROSS" = 1 ] && wrapper=true
  cat > "$CROSS_FILE" <<EOF
[binaries]
c = ['$CLANG', '-arch', '$A']
cpp = ['$CLANGXX', '-arch', '$A']
objc = ['$CLANG', '-arch', '$A']
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
ranlib = '$(xcrun -f ranlib)'
pkg-config = '$(command -v pkg-config)'
nasm = '$(command -v nasm)'

[built-in options]
c_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-I$PREFIX/include']
cpp_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-I$PREFIX/include']
objc_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-I$PREFIX/include']
c_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-L$PREFIX/lib']
cpp_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-L$PREFIX/lib']
objc_link_args = ['-isysroot', '$SDK', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-L$PREFIX/lib']

[properties]
needs_exe_wrapper = $wrapper
pkg_config_libdir = '$PREFIX/lib/pkgconfig'

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = '$CPU_FAMILY'
cpu = '$A'
endian = 'little'
EOF
}

# stamp key: name + version + source sha + configuration string
stamp_path() { # name arch ver sha config...
  local name="$1" arch="$2" ver="$3" sha="$4"; shift 4
  local key; key="$(printf '%s|%s|%s|%s|%s|%s' "$name" "$arch" "$ver" "$sha" "$*" "$DEPLOYMENT_TARGET" | shasum -a 256 | cut -c1-16)"
  echo "$STAMPS/$name-$arch-$key"
}

# run_component name ver sha builder-fn config...
run_component() {
  local name="$1" ver="$2" sha="$3" fn="$4"; shift 4
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && return 0
  local stamp; stamp="$(stamp_path "$name" "$A" "$ver" "$sha" "$@")"
  if [ -f "$stamp" ]; then log "$name $ver [$A] up to date"; return 0; fi
  rm -f "$STAMPS/$name-$A-"*
  log "building $name $ver [$A]"
  local t0=$SECONDS
  rm -rf "$BUILD/$name"; mkdir -p "$BUILD/$name"
  "$fn"
  local dt=$((SECONDS - t0))
  echo "$dt" > "$stamp"
  log "$name $ver [$A] done in ${dt}s"
}

meson_build() { # name srcdir extra-args...
  local name="$1" src="$2"; shift 2
  meson setup "$BUILD/$name/build" "$src" \
    --cross-file "$CROSS_FILE" --prefix "$PREFIX" --libdir lib --buildtype "${MESON_BUILDTYPE:-minsize}" \
    --default-library shared --wrap-mode nodownload -Dstrip=false "$@"
  meson compile -C "$BUILD/$name/build" -j "$JOBS"
  meson install -C "$BUILD/$name/build" >/dev/null
}

# ---------------------------------------------------------------------------------------------
# Component builders (run with the per-arch globals set by arch_setup)
# ---------------------------------------------------------------------------------------------
build_dav1d()     { MESON_BUILDTYPE=release meson_build dav1d "$(src_of dav1d $DAV1D_VER)" "${DAV1D_ARGS[@]}"; }
build_freetype()  { meson_build freetype "$(src_of freetype $FREETYPE_VER)" "${FREETYPE_ARGS[@]}"; }
build_fribidi()   { meson_build fribidi "$(src_of fribidi $FRIBIDI_VER)" "${FRIBIDI_ARGS[@]}"; }
build_harfbuzz()  { meson_build harfbuzz "$(src_of harfbuzz $HARFBUZZ_VER)" "${HARFBUZZ_ARGS[@]}"; }
build_libplacebo() {
  local src; src="$(src_of libplacebo $LIBPLACEBO_VER)"
  mkdir -p "$src/3rdparty/jinja" "$src/3rdparty/markupsafe"
  mkdir -p "$src/3rdparty/Vulkan-Headers"
  ln -sfn "$(src_of vulkan-headers $VULKAN_HEADERS_VER)/include" "$src/3rdparty/Vulkan-Headers/include"
  mkdir -p "$src/3rdparty/fast_float"
  ln -sfn "$(src_of fast_float $FAST_FLOAT_VER)/include" "$src/3rdparty/fast_float/include"
  ln -sfn "$(src_of jinja $JINJA_VER)/src" "$src/3rdparty/jinja/src"
  ln -sfn "$(src_of markupsafe $MARKUPSAFE_VER)/src" "$src/3rdparty/markupsafe/src"
  meson_build libplacebo "$src" "${LIBPLACEBO_ARGS[@]}"
}
build_mpv() {
  # mpv invokes swiftc without a target, so pin it for cross builds.
  meson_build mpv "$(src_of mpv $MPV_VER)" "${MPV_ARGS[@]}" "-Dswift-flags=-target $A-apple-macos$DEPLOYMENT_TARGET"
}

build_libass() {
  local src; src="$(src_of libass $LIBASS_VER)"
  ( cd "$BUILD/libass"
    CC="$CLANG -arch $A" CFLAGS="$COMMON_FLAGS" LDFLAGS="$LINK_FLAGS" \
    NASM="$(command -v nasm)" \
    "$src/configure" --prefix="$PREFIX" --host="$TRIPLE" "${LIBASS_ARGS[@]}"
    make -j"$JOBS"
    make install >/dev/null )
}

build_ffmpeg() {
  local src; src="$(src_of ffmpeg $FFMPEG_VER)"
  local cross_args=()
  [ "$CROSS" = 1 ] && cross_args=(--enable-cross-compile)
  ( cd "$BUILD/ffmpeg"
    "$src/configure" --prefix="$PREFIX" --arch="$FF_ARCH" --target-os=darwin \
      --host-cc="$CLANG -arch $HOST_ARCH" --host-cflags="-isysroot $SDK" --host-ldflags="-isysroot $SDK" \
      --cc="$CLANG -arch $A" --cxx="$CLANGXX -arch $A" --objcc="$CLANG -arch $A" \
      --x86asmexe="$(command -v nasm)" --pkg-config="$(command -v pkg-config)" \
      ${cross_args[@]+"${cross_args[@]}"} \
      --extra-cflags="$COMMON_FLAGS" --extra-ldflags="$LINK_FLAGS" --extra-libs=-liconv \
      "${FFMPEG_ARGS[@]}"
    make -j"$JOBS"
    make install >/dev/null
    cp ffbuild/config.log "$PREFIX/ffmpeg-config.log" 2>/dev/null || true
    cp config.h "$PREFIX/ffmpeg-config.h" )
}

# ---------------------------------------------------------------------------------------------
# Stage: collect the dylibs libmpv actually needs, fix install names, strip, lipo, sign.
# ---------------------------------------------------------------------------------------------
deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

stage_arch() { # arch -> $CACHE/stage/<arch>/*.dylib
  local arch="$1" prefix="$CACHE/prefix/$arch" out="$CACHE/stage/$arch"
  rm -rf "$out"; mkdir -p "$out"
  local queue=("$prefix/lib/libmpv.2.dylib") seen=" "
  [ -e "${queue[0]}" ] || die "libmpv.2.dylib not found in $prefix/lib (build incomplete?)"
  while [ ${#queue[@]} -gt 0 ]; do
    local cur="${queue[0]}"; queue=("${queue[@]:1}")
    local base; base="$(basename "$cur")"
    case "$seen" in *" $base "*) continue ;; esac
    seen="$seen$base "
    cp -L "$cur" "$out/$base"; chmod u+w "$out/$base"
    local d
    for d in $(deps_of "$out/$base"); do
      case "$d" in
        "$prefix"/lib/*) queue+=("$d") ;;
        /usr/lib/*|/System/*|@rpath/*|@loader_path/*) ;;
        *) die "$base [$arch] links against disallowed path: $d" ;;
      esac
    done
  done
  local f d
  for f in "$out"/*.dylib; do
    local base; base="$(basename "$f")"
    install_name_tool -id "@rpath/$base" "$f"
    for d in $(deps_of "$f"); do
      case "$d" in "$prefix"/lib/*) install_name_tool -change "$d" "@rpath/$(basename "$d")" "$f" ;; esac
    done
    # find siblings next to us regardless of the host executable's rpaths
    install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
    # drop absolute rpaths into build prefixes / the Xcode toolchain (keep /usr/lib/swift for the OS Swift runtime)
    local rp
    for rp in $(otool -l "$f" | awk '/LC_RPATH/{getline; getline; print $2}'); do
      case "$rp" in @*|/usr/lib/swift) ;; *) install_name_tool -delete_rpath "$rp" "$f" ;; esac
    done
    strip -x "$f"
    codesign --force --sign - "$f" 2>/dev/null
  done
}

stage_universal() {
  local out="$CACHE/universal"
  rm -rf "$out"; mkdir -p "$out"
  local f
  for f in "$CACHE/stage/${ARCHES[0]}"/*.dylib; do
    local base; base="$(basename "$f")"
    local inputs=() a
    for a in "${ARCHES[@]}"; do inputs+=("$CACHE/stage/$a/$base"); done
    if [ ${#ARCHES[@]} -gt 1 ]; then lipo -create "${inputs[@]}" -output "$out/$base"; else cp "$f" "$out/$base"; fi
    codesign --force --sign - "$out/$base" 2>/dev/null
  done
}

install_stage() {
  log "staging into $STAGE_OUT"
  rm -rf "$STAGE_OUT"; mkdir -p "$STAGE_OUT/lib" "$STAGE_OUT/include/mpv" "$STAGE_OUT/licenses"
  cp "$CACHE"/universal/*.dylib "$STAGE_OUT/lib/"
  cp "$(src_of mpv $MPV_VER)"/include/mpv/*.h "$STAGE_OUT/include/mpv/"
  local pair
  for pair in "ffmpeg:$FFMPEG_VER" "dav1d:$DAV1D_VER" "freetype:$FREETYPE_VER" "fribidi:$FRIBIDI_VER" \
              "harfbuzz:$HARFBUZZ_VER" "libass:$LIBASS_VER" "libplacebo:$LIBPLACEBO_VER" "mpv:$MPV_VER"; do
    local n="${pair%%:*}" v="${pair##*:}" s
    s="$(src_of "$n" "$v")"
    mkdir -p "$STAGE_OUT/licenses/$n"
    local lf
    for lf in COPYING COPYING.LGPLv2.1 COPYING.LGPLv3 COPYING.BSD LICENSE LICENSE.LGPL LICENSE.md LICENSE.txt \
              COPYING.txt docs/LICENSE.TXT docs/FTL.TXT docs/GPLv2.TXT docs/LICENSE.TXT; do
      [ -f "$s/$lf" ] && cp "$s/$lf" "$STAGE_OUT/licenses/$n/" 2>/dev/null || true
    done
  done
  {
    echo "mpv $MPV_VER, ffmpeg $FFMPEG_VER, dav1d $DAV1D_VER, libass $LIBASS_VER, libplacebo $LIBPLACEBO_VER,"
    echo "freetype $FREETYPE_VER, harfbuzz $HARFBUZZ_VER, fribidi $FRIBIDI_VER"
    echo "arches: ${ARCHES[*]}  deployment target: $DEPLOYMENT_TARGET  built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "ffmpeg configure: ${FFMPEG_ARGS[*]}"
    echo "mpv meson: ${MPV_ARGS[*]}"
  } > "$STAGE_OUT/BUILD-INFO.txt"
}

# ---------------------------------------------------------------------------------------------
# Verification: linkage + LGPL evidence
# ---------------------------------------------------------------------------------------------
verify() {
  log "verifying $STAGE_OUT"
  local f bad=0
  for f in "$STAGE_OUT"/lib/*.dylib; do
    [ -L "$f" ] && continue
    local archs; archs="$(lipo -archs "$f")"
    for want in "${ARCHES[@]}"; do
      case " $archs " in *" $want "*) ;; *) echo "FAIL $f lacks $want ($archs)"; bad=1 ;; esac
    done
    local d
    for d in $(deps_of "$f" | tail -n +2); do   # first line is the install name
      case "$d" in
        /usr/lib/*|/System/*|@rpath/*) ;;
        *) echo "FAIL $(basename "$f") -> $d"; bad=1 ;;
      esac
    done
    if otool -l "$f" | grep -A2 LC_RPATH | grep -E 'path /' | grep -qv 'path /usr/lib/swift'; then
      echo "FAIL $(basename "$f") has an absolute rpath"; bad=1
    fi
    if otool -l "$f" | grep -B1 -A4 LC_BUILD_VERSION | grep -q "minos 1[6-9]\|minos [2-9][0-9]"; then
      echo "FAIL $(basename "$f") minos above $DEPLOYMENT_TARGET"; bad=1
    fi
  done
  [ "$bad" = 0 ] || die "linkage verification failed"

  # LGPL evidence, executed against the real dylibs for the host arch (skipped for a foreign-only build).
  case " ${ARCHES[*]} " in *" $HOST_ARCH "*) ;; *) log "verification passed (no host-arch slice to execute)"; return 0 ;; esac
  local tdir; tdir="$(mktemp -d)"
  cat > "$tdir/lic.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <libavutil/avutil.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <mpv/client.h>
int main(void) {
  const char *l[] = { avutil_license(), avcodec_license(), avformat_license(), avfilter_license(),
                      swscale_license(), swresample_license() };
  int bad = 0;
  for (int i = 0; i < 6; i++) { printf("ffmpeg lib %d: %s\n", i, l[i]); if (!strstr(l[i], "LGPL") || strstr(l[i], "GPL version 2 or later") == l[i]) bad = 1; }
  printf("avutil_configuration: %s\n", avutil_configuration());
  if (strstr(avutil_configuration(), "--enable-gpl") || strstr(avutil_configuration(), "--enable-nonfree") ||
      strstr(avutil_configuration(), "--enable-version3")) bad = 1;
  mpv_handle *h = mpv_create();
  mpv_set_option_string(h, "vo", "null"); mpv_set_option_string(h, "ao", "null");
  if (mpv_initialize(h) < 0) { puts("mpv_initialize failed"); return 2; }
  char *cfg = mpv_get_property_string(h, "mpv-configuration");
  printf("mpv-configuration: %s\n", cfg ? cfg : "(null)");
  char *ver = mpv_get_property_string(h, "mpv-version");
  printf("mpv-version: %s\n", ver ? ver : "(null)");
  char *ff = mpv_get_property_string(h, "ffmpeg-version");
  printf("ffmpeg-version: %s\n", ff ? ff : "(null)");
  if (!cfg || !strstr(cfg, "-Dgpl=false")) { puts("mpv is not a -Dgpl=false build"); bad = 1; }
  mpv_terminate_destroy(h);
  return bad;
}
EOF
  local inc="$CACHE/prefix/$HOST_ARCH/include"
  [ -d "$inc" ] || inc="$(ls -d "$CACHE"/prefix/*/include | head -1)"
  "$CLANG" -arch "$HOST_ARCH" -isysroot "$SDK" -I"$inc" -I"$STAGE_OUT/include" "$tdir/lic.c" \
    "$STAGE_OUT/lib/libmpv.2.dylib" "$STAGE_OUT"/lib/libavutil.[0-9]*.dylib "$STAGE_OUT"/lib/libavcodec.[0-9]*.dylib \
    "$STAGE_OUT"/lib/libavformat.[0-9]*.dylib "$STAGE_OUT"/lib/libavfilter.[0-9]*.dylib \
    "$STAGE_OUT"/lib/libswscale.[0-9]*.dylib "$STAGE_OUT"/lib/libswresample.[0-9]*.dylib \
    -Wl,-rpath,"$STAGE_OUT/lib" -o "$tdir/lic" || die "could not build license probe"
  "$tdir/lic" || die "LGPL verification failed"
  rm -rf "$tdir"
  log "verification passed"
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
if [ "$VERIFY_ONLY" = 1 ]; then ARCHES=("$HOST_ARCH"); [ -d "$CACHE/prefix" ] || ARCHES=("$HOST_ARCH"); verify; exit 0; fi

log "fetching sources"
fetch ffmpeg "$FFMPEG_VER" "$FFMPEG_URL" "$FFMPEG_SHA"
fetch dav1d "$DAV1D_VER" "$DAV1D_URL" "$DAV1D_SHA"
fetch freetype "$FREETYPE_VER" "$FREETYPE_URL" "$FREETYPE_SHA"
fetch fribidi "$FRIBIDI_VER" "$FRIBIDI_URL" "$FRIBIDI_SHA"
fetch harfbuzz "$HARFBUZZ_VER" "$HARFBUZZ_URL" "$HARFBUZZ_SHA"
fetch libass "$LIBASS_VER" "$LIBASS_URL" "$LIBASS_SHA"
fetch libplacebo "$LIBPLACEBO_VER" "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA"
fetch vulkan-headers "$VULKAN_HEADERS_VER" "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA"
fetch fast_float "$FAST_FLOAT_VER" "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA"
fetch jinja "$JINJA_VER" "$JINJA_URL" "$JINJA_SHA"
fetch markupsafe "$MARKUPSAFE_VER" "$MARKUPSAFE_URL" "$MARKUPSAFE_SHA"
fetch mpv "$MPV_VER" "$MPV_URL" "$MPV_SHA"

for arch in "${ARCHES[@]}"; do
  arch_setup "$arch"
  CFG_COMMON="clang=$($CLANG --version | head -1)|sdk=$(basename "$SDK")"
  run_component dav1d "$DAV1D_VER" "$DAV1D_SHA" build_dav1d "${DAV1D_ARGS[*]}|$CFG_COMMON"
  run_component freetype "$FREETYPE_VER" "$FREETYPE_SHA" build_freetype "${FREETYPE_ARGS[*]}|bt=minsize|$CFG_COMMON"
  run_component fribidi "$FRIBIDI_VER" "$FRIBIDI_SHA" build_fribidi "${FRIBIDI_ARGS[*]}|bt=minsize|$CFG_COMMON"
  run_component harfbuzz "$HARFBUZZ_VER" "$HARFBUZZ_SHA" build_harfbuzz "${HARFBUZZ_ARGS[*]}|bt=minsize|$CFG_COMMON"
  run_component libass "$LIBASS_VER" "$LIBASS_SHA" build_libass "${LIBASS_ARGS[*]}|$CFG_COMMON"
  run_component ffmpeg "$FFMPEG_VER" "$FFMPEG_SHA" build_ffmpeg "${FFMPEG_ARGS[*]}|$CFG_COMMON"
  run_component libplacebo "$LIBPLACEBO_VER" "$LIBPLACEBO_SHA" build_libplacebo "${LIBPLACEBO_ARGS[*]}|vkh$VULKAN_HEADERS_VER|fast_float$FAST_FLOAT_VER|jinja$JINJA_VER|markupsafe$MARKUPSAFE_VER|bt=minsize|$CFG_COMMON"
  run_component mpv "$MPV_VER" "$MPV_SHA" build_mpv "${MPV_ARGS[*]}|bt=minsize|$CFG_COMMON"
done

[ -n "$ONLY" ] && { log "built $ONLY; skipping staging"; exit 0; }

for arch in "${ARCHES[@]}"; do log "staging $arch"; stage_arch "$arch"; done
stage_universal
install_stage
verify
if [ "$FULL" = 1 ]; then
  mkdir -p "$OUT"
  rsync -a --delete "$STAGE_OUT/" "$OUT/"
  touch "$OUT/.complete"
fi

log "done. Sizes:"
for arch in "${ARCHES[@]}"; do du -ck "$CACHE/stage/$arch"/*.dylib | tail -1 | awk -v a="$arch" '{printf "  %-7s %6d KiB\n", a, $1}'; done
du -ck "$STAGE_OUT"/lib/*.dylib | tail -1 | awk '{printf "  %-7s %6d KiB\n", "univ", $1}'
