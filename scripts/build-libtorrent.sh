#!/usr/bin/env bash
# Builds libtorrent-rasterbar (+ OpenSSL, + the Boost headers it needs) as universal
# (arm64 + x86_64) static libraries and installs them into Vendor/libtorrent/.
#
#   scripts/build-libtorrent.sh              build (or reuse cache) and install into Vendor/libtorrent
#   scripts/build-libtorrent.sh --force      ignore Vendor/ and the cache, rebuild everything
#   scripts/build-libtorrent.sh --print-key  print the cache key (versions + script hash) and exit
#
# Environment:
#   MARQUEE_DEPS_CACHE  where downloads, build trees and finished outputs live
#                       (default: ~/Library/Caches/Marquee/deps). Safe to share between
#                       worktrees. CI caches "$MARQUEE_DEPS_CACHE/out".
#   DEVELOPER_DIR       Xcode to build with (the script never touches xcode-select).
#   JOBS                parallel build jobs (default: all cores).
#
# The script is idempotent: Vendor/libtorrent/.build-key records what is installed, and a
# finished build for the same key is reused from the cache without compiling anything.
# This file's hash is part of the key, so editing the script forces a rebuild.
#
# Crypto choice: libtorrent ships its own RC4 + Diffie-Hellman, so BitTorrent protocol
# encryption (-Dencryption=ON) needs no crypto library. OpenSSL is linked only for TLS
# (HTTPS trackers, web seeds, SSL torrents) and is built trimmed (libssl + libcrypto only).
set -euo pipefail

# ---- pinned inputs (bump deliberately; every sha256 is verified before use) -----------------
LIBTORRENT_VERSION=2.0.15
LIBTORRENT_URL="https://github.com/arvidn/libtorrent/releases/download/v${LIBTORRENT_VERSION}/libtorrent-rasterbar-${LIBTORRENT_VERSION}.tar.gz"
LIBTORRENT_SHA256=5e2e79129823b7ea48721164c32b5aaf83d3fd733b5502100f6705b29f27bb02

OPENSSL_VERSION=3.5.9   # 3.5 is an LTS line (supported until 2030)
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

BOOST_VERSION=1.90.0    # headers only; libtorrent 2.0 needs no compiled Boost libraries
BOOST_URL="https://github.com/boostorg/boost/releases/download/boost-${BOOST_VERSION}/boost-${BOOST_VERSION}-b2-nodocs.tar.xz"
BOOST_SHA256=9e6bee9ab529fb2b0733049692d57d10a72202af085e553539a05b4204211a6f

ARCHS=(arm64 x86_64)
MIN_MACOS=15.0
# ----------------------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HASH="$(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-12)"
KEY="lt${LIBTORRENT_VERSION}-ossl${OPENSSL_VERSION}-boost${BOOST_VERSION}-${SCRIPT_HASH}"

if [[ "${1:-}" == "--print-key" ]]; then echo "$KEY"; exit 0; fi
FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

CACHE="${MARQUEE_DEPS_CACHE:-$HOME/Library/Caches/Marquee/deps}"
DOWNLOADS="$CACHE/downloads"
OUT="$CACHE/out/$KEY"
VENDOR="$ROOT/Vendor/libtorrent"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_to_vendor() {
  mkdir -p "$VENDOR"
  rsync -a --delete "$OUT/" "$VENDOR/"
  echo "$KEY" > "$VENDOR/.build-key"
  log "Installed $KEY into Vendor/libtorrent"
}

if [[ $FORCE -eq 0 ]]; then
  if [[ "$(cat "$VENDOR/.build-key" 2>/dev/null || true)" == "$KEY" ]]; then
    log "Vendor/libtorrent is up to date ($KEY)"; exit 0
  fi
  if [[ -f "$OUT/.complete" ]]; then
    log "Reusing cached build $KEY"; install_to_vendor; exit 0
  fi
fi

# ---- preflight --------------------------------------------------------------------------------
for tool in cmake perl curl tar lipo xcrun rsync shasum; do
  command -v "$tool" >/dev/null || die "missing build tool '$tool' (try: brew install cmake)"
done
GENERATOR="Unix Makefiles"; command -v ninja >/dev/null && GENERATOR="Ninja"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
log "libtorrent $LIBTORRENT_VERSION, OpenSSL $OPENSSL_VERSION, Boost $BOOST_VERSION ($GENERATOR, $JOBS jobs)"
log "SDK: $SDK"

# ---- download + verify ------------------------------------------------------------------------
mkdir -p "$DOWNLOADS"
fetch() { # url sha256 -> prints the verified local path
  local url="$1" sha="$2" file="$DOWNLOADS/$(basename "$1")"
  if [[ -f "$file" ]] && [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$sha" ]]; then echo "$file"; return; fi
  log "Downloading $(basename "$url")" >&2
  curl -fsSL --retry 3 -o "$file.part" "$url"
  local got; got="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$file.part"; die "sha256 mismatch for $(basename "$url"): expected $sha, got $got"
  fi
  mv "$file.part" "$file"; echo "$file"
}
LT_TAR="$(fetch "$LIBTORRENT_URL" "$LIBTORRENT_SHA256")"
SSL_TAR="$(fetch "$OPENSSL_URL" "$OPENSSL_SHA256")"
BOOST_TAR="$(fetch "$BOOST_URL" "$BOOST_SHA256")"

# ---- unpack -----------------------------------------------------------------------------------
WORK="$CACHE/build/$KEY"
# A failed run leaves $WORK behind and the next run resumes from it (finished arch builds are
# skipped, unfinished ones continue incrementally). --force starts from scratch.
[[ $FORCE -eq 1 ]] && rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/logs"
trap 'status=$?; [[ $status -ne 0 ]] && echo "build failed; logs in $WORK/logs" >&2; exit $status' EXIT
if [[ ! -f "$WORK/src/.unpacked" ]]; then
  log "Unpacking sources"
  tar -xzf "$LT_TAR"  -C "$WORK/src"
  tar -xzf "$SSL_TAR" -C "$WORK/src"
  tar -xJf "$BOOST_TAR" -C "$WORK/src" "boost-${BOOST_VERSION}/boost" "boost-${BOOST_VERSION}/LICENSE_1_0.txt"
  touch "$WORK/src/.unpacked"
fi
LT_SRC="$WORK/src/libtorrent-rasterbar-${LIBTORRENT_VERSION}"
SSL_SRC="$WORK/src/openssl-${OPENSSL_VERSION}"
BOOST_DIR="$WORK/src/boost-${BOOST_VERSION}"

# ---- per-architecture builds ----------------------------------------------------------------
build_openssl() { # arch prefix
  local arch="$1" prefix="$2"
  mkdir -p "$WORK/openssl-$arch" && pushd "$WORK/openssl-$arch" >/dev/null
  # Static libssl + libcrypto only. Everything libtorrent does not need for TLS is compiled
  # out to keep the binary small (no engines, legacy provider, DTLS/QUIC, exotic ciphers, ...).
  "$SSL_SRC/Configure" "darwin64-$arch-cc" --prefix="$prefix" --openssldir="$prefix/ssl" \
    no-shared no-tests no-apps no-docs no-legacy no-engine no-dso no-module no-comp \
    no-ssl3 no-dtls no-quic no-srp no-psk no-sctp no-srtp no-ct no-cms no-ts no-ocsp \
    no-gost no-idea no-seed no-rc2 no-rc4 no-rc5 no-bf no-cast no-camellia no-aria \
    no-sm2 no-sm3 no-sm4 no-md2 no-md4 no-mdc2 no-whirlpool no-weak-ssl-ciphers no-ssl-trace \
    -O2 "-mmacosx-version-min=$MIN_MACOS" >"$WORK/logs/openssl-$arch.configure.log" 2>&1
  make -j"$JOBS" build_libs >"$WORK/logs/openssl-$arch.build.log" 2>&1
  make install_dev >"$WORK/logs/openssl-$arch.install.log" 2>&1
  popd >/dev/null
}

build_libtorrent() { # arch prefix openssl-prefix
  local arch="$1" prefix="$2" ssl="$3" bdir="$WORK/libtorrent-$1"
  cmake -S "$LT_SRC" -B "$bdir" -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -g0 -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O2 -g0 -DNDEBUG -fvisibility=hidden -fvisibility-inlines-hidden" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF -Dstatic_runtime=OFF \
    -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF \
    -Ddeprecated-functions=OFF -Dlogging=OFF -Di2p=OFF \
    -Dencryption=ON -Dgnutls=OFF -Dexceptions=ON \
    -Ddht=ON -Dextensions=ON -Dmutable-torrents=ON -Dstreaming=ON \
    -DBoost_NO_BOOST_CMAKE=ON -DBOOST_ROOT="$BOOST_DIR" -DBoost_INCLUDE_DIR="$BOOST_DIR" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DOPENSSL_ROOT_DIR="$ssl" -DOPENSSL_USE_STATIC_LIBS=ON \
    >"$WORK/logs/libtorrent-$arch.configure.log" 2>&1
  cmake --build "$bdir" -j "$JOBS" >"$WORK/logs/libtorrent-$arch.build.log" 2>&1
  cmake --install "$bdir" >"$WORK/logs/libtorrent-$arch.install.log" 2>&1
}

TIMINGS=""
for arch in "${ARCHS[@]}"; do
  prefix="$WORK/install-$arch"
  if [[ -f "$prefix/.done" ]]; then
    log "[$arch] already built"; TIMINGS+="$(cat "$prefix/.done")"$'\n'; continue
  fi
  start=$SECONDS
  log "[$arch] building OpenSSL"
  build_openssl "$arch" "$prefix/openssl"
  ossl_done=$SECONDS
  log "[$arch] building libtorrent"
  build_libtorrent "$arch" "$prefix/libtorrent" "$prefix/openssl"
  line="$arch: openssl $((ossl_done-start))s, libtorrent $((SECONDS-ossl_done))s, total $((SECONDS-start))s"
  echo "$line" > "$prefix/.done"; TIMINGS+="$line"$'\n'
done

# ---- assemble outputs: universal libs + the minimal header closure ----------------------------
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include" "$STAGE/licenses"
for spec in "libtorrent-rasterbar.a:libtorrent/lib/libtorrent-rasterbar.a" \
            "libssl.a:openssl/lib/libssl.a" "libcrypto.a:openssl/lib/libcrypto.a"; do
  name="${spec%%:*}"; rel="${spec#*:}"
  inputs=(); for arch in "${ARCHS[@]}"; do inputs+=("$WORK/install-$arch/$rel"); done
  lipo -create "${inputs[@]}" -output "$STAGE/lib/$name"
done

# Compile definitions libtorrent's headers need to see (they change struct layouts), taken from
# the generated pkg-config file so the shim is compiled with exactly the same ones.
PC="$(find "$WORK/install-${ARCHS[0]}/libtorrent" -name 'libtorrent-rasterbar.pc' | head -1)"
grep '^Cflags:' "$PC" | tr ' ' '\n' | grep '^-D' | sed 's/^-D//' | sort -u > "$WORK/defines.txt"

# libtorrent's and OpenSSL's public headers are copied whole. Boost is reduced to the headers the
# preprocessor actually reaches from every public libtorrent header (a few MB instead of ~150).
cp -R "$WORK/install-${ARCHS[0]}/libtorrent/include/libtorrent" "$STAGE/include/libtorrent"
cp -R "$WORK/install-${ARCHS[0]}/openssl/include/openssl" "$STAGE/include/openssl"
CLOSURE_TU="$WORK/closure.cpp"
# (io_service.hpp and storage.hpp are intentional #error stubs for removed 1.x APIs.)
( cd "$STAGE/include" && find libtorrent -name '*.hpp' ! -path '*/aux_/*' ! -name io_service.hpp ! -name storage.hpp \
    | LC_ALL=C sort | sed 's/.*/#include <&>/' ) > "$CLOSURE_TU"
DEFS=(); while IFS= read -r d; do DEFS+=("-D$d"); done < "$WORK/defines.txt"
# Shipped as a header that Sources/CTorrentShim/shim.cpp includes before any libtorrent header, so
# Package.swift needs no knowledge of the build configuration.
{
  echo "// Generated by scripts/build-libtorrent.sh: the definitions libtorrent was compiled with."
  echo "#pragma once"
  while IFS= read -r d; do
    if [[ "$d" == *=* ]]; then echo "#define ${d%%=*} ${d#*=}"; else echo "#define $d 1"; fi
  done < "$WORK/defines.txt"
} > "$STAGE/include/marquee_libtorrent_config.h"
: > "$WORK/boost-headers.txt"
for arch in "${ARCHS[@]}"; do
  xcrun clang++ -arch "$arch" -std=c++17 -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS" "${DEFS[@]}" \
    -I"$STAGE/include" -I"$BOOST_DIR" -M "$CLOSURE_TU" \
    | tr -s ' \\' '\n\n' | { grep "^$BOOST_DIR/boost/" || true; } >> "$WORK/boost-headers.txt"
done
LC_ALL=C sort -u "$WORK/boost-headers.txt" | sed "s|^$BOOST_DIR/||" > "$WORK/boost-headers.sorted"
( cd "$BOOST_DIR" && rsync -a --files-from="$WORK/boost-headers.sorted" . "$STAGE/include/" )
# Prove the staged tree is self-contained (no reference back to the full Boost tree).
for arch in "${ARCHS[@]}"; do
  xcrun clang++ -arch "$arch" -std=c++17 -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS" "${DEFS[@]}" \
    -I"$STAGE/include" -fsyntax-only -x c++ "$CLOSURE_TU"
done

cp "$LT_SRC/COPYING" "$STAGE/licenses/libtorrent-COPYING.txt"
cp "$SSL_SRC/LICENSE.txt" "$STAGE/licenses/openssl-LICENSE.txt"
cp "$BOOST_DIR/LICENSE_1_0.txt" "$STAGE/licenses/boost-LICENSE_1_0.txt"
{
  echo "key: $KEY"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(xcrun clang++ --version | head -1)"
  echo "host: $(uname -m), $JOBS jobs"
  echo "timings:"; printf '%s' "$TIMINGS" | sed 's/^/  /'
  echo "sizes (universal):"; ls -l "$STAGE/lib" | awk 'NR>1 {printf "  %s %d bytes\n", $9, $5}'
  echo "boost headers kept: $(wc -l < "$WORK/boost-headers.sorted" | tr -d ' ')"
} > "$STAGE/BUILD-INFO.txt"
touch "$STAGE/.complete"

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"; mv "$STAGE" "$OUT"
rm -rf "$WORK"   # sources and build trees are large; downloads stay cached
trap - EXIT
install_to_vendor
cat "$VENDOR/BUILD-INFO.txt"
