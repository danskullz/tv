#!/usr/bin/env bash
# Builds the signed update manifest ("appcast") that Marquee's in-app updater reads from
# https://tv.guihot.net/appcast.json, plus its detached Ed25519 signature.
#
#   scripts/make-appcast.sh --version 0.1.29 --dir dist --base https://tv.guihot.net \
#       --out site --key ~/.config/marquee/appcast-key.pem
#
# Environment:
#   SOURCE_DATE_EPOCH  fixed timestamp for generatedAt/publishedAt (default: the newest
#                      artifact mtime, which keeps re-runs byte-identical).
#
# The output is deterministic: same inputs -> same bytes. That is what makes the signature safe
# to compare against the file the client downloads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/make-appcast.sh --version <0.1.29> --dir <dist dir> --base https://tv.guihot.net
                               [--out <site dir>] [--channel beta|stable] [--stable]
                               [--notes-file <path>] [--key <pem>] [--key-id <id>]
                               [--minimum-version <0.1.20>] [--yanked] [--replace]
                               [--app com.danskullz.marquee] [--min-os 15.0]
                               [--generated-at <iso8601>] [--changelog <path>]
                               [--previous <path>]
  --print-keyring        print the paste-ready Swift keyring entry for --key and exit
  --previous             manifest to carry earlier releases forward from (default: the
                         appcast.json already in --out). CI passes the live one it just fetched,
                         because the feed lives only on the VPS and is never committed.

Defaults: --out <repo>/site, --channel beta, --key-id marquee-2026, --min-os 15.0,
          --base https://tv.guihot.net, --changelog <repo>/CHANGELOG.md.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

VERSION=""
DIST_DIR=""
BASE=""
OUT=""
CHANNEL="beta"
STABLE=0
NOTES_FILE=""
KEY=""
KEY_ID="marquee-2026"
MINIMUM_VERSION=""
YANKED=0
REPLACE=0
APP_ID="com.danskullz.marquee"
MIN_OS="15.0"
GENERATED_AT=""
CHANGELOG=""
PREVIOUS=""
PRINT_KEYRING=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)          VERSION="${2:?--version needs a value}"; shift 2 ;;
    --dir)              DIST_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --base)             BASE="${2:?--base needs a value}"; shift 2 ;;
    --out)              OUT="${2:?--out needs a value}"; shift 2 ;;
    --channel)          CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
    --stable)           STABLE=1; shift ;;
    --notes-file)       NOTES_FILE="${2:?--notes-file needs a value}"; shift 2 ;;
    --key)              KEY="${2:?--key needs a value}"; shift 2 ;;
    --key-id)           KEY_ID="${2:?--key-id needs a value}"; shift 2 ;;
    --minimum-version)  MINIMUM_VERSION="${2:?--minimum-version needs a value}"; shift 2 ;;
    --yanked)           YANKED=1; shift ;;
    --replace)          REPLACE=1; shift ;;
    --app)              APP_ID="${2:?--app needs a value}"; shift 2 ;;
    --min-os)           MIN_OS="${2:?--min-os needs a value}"; shift 2 ;;
    --generated-at)     GENERATED_AT="${2:?--generated-at needs a value}"; shift 2 ;;
    --changelog)        CHANGELOG="${2:?--changelog needs a value}"; shift 2 ;;
    --previous)         PREVIOUS="${2:?--previous needs a value}"; shift 2 ;;
    --print-keyring)    PRINT_KEYRING=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; die "unknown argument: $1" ;;
  esac
done

if [ "$STABLE" = 1 ]; then CHANNEL="stable"; fi
case "$CHANNEL" in
  beta|stable) ;;
  *) die "--channel must be 'beta' or 'stable' (got '$CHANNEL')" ;;
esac
if [ -z "$BASE" ]; then BASE="https://tv.guihot.net"; fi
if [ -z "$OUT" ]; then OUT="$ROOT/site"; fi
if [ -z "$CHANGELOG" ]; then CHANGELOG="$ROOT/CHANGELOG.md"; fi

command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required but not installed"

# macOS ships LibreSSL at /usr/bin/openssl and it has no Ed25519 at all -- `genpkey` answers
# "Algorithm ed25519 not found". A Homebrew OpenSSL 3 earlier in PATH works, so the fix is to find
# one that can actually sign rather than to hope the machine has it. Checked once, up front, with a
# message that says what to do: left to chance, this fails at signing time and reads like a
# problem with the key rather than the tool.
openssl_supports_ed25519() {
  local probe
  probe="$(mktemp -d)"
  if openssl genpkey -algorithm ed25519 -out "$probe/k.pem" >/dev/null 2>&1 && [ -s "$probe/k.pem" ]; then
    rm -rf "$probe"
    return 0
  fi
  rm -rf "$probe"
  return 1
}

if ! openssl_supports_ed25519; then
  die "the openssl on PATH ($(command -v openssl), $(openssl version 2>/dev/null)) cannot do Ed25519.
     macOS ships LibreSSL at /usr/bin/openssl, which cannot. Install OpenSSL 3 and put it first:
       brew install openssl@3 && export PATH=\"$(brew --prefix openssl@3 2>/dev/null)/bin:\$PATH\""
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# --- --print-keyring: the raw 32-byte public key is the tail of the DER SPKI encoding. -------
if [ "$PRINT_KEYRING" = 1 ]; then
  [ -n "$KEY" ] || die "--print-keyring needs --key <pem>"
  [ -f "$KEY" ] || die "key not found: $KEY"
  PUBKEY_B64="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')"
  [ "${#PUBKEY_B64}" -eq 44 ] || die "could not derive an Ed25519 public key from $KEY"
  cat <<EOF
// scripts/site/appcast-keyring.md -- pinned Ed25519 public keys for the update channel.
// Keep every key you have ever shipped; a client that finds no match must refuse to update.
enum AppcastKeyring {
    static let keys: [String: Data] = [
        "$KEY_ID": Data(base64Encoded: "$PUBKEY_B64")!
    ]
}
EOF
  exit 0
fi

[ -n "$VERSION" ] || { usage >&2; die "--version is required"; }
[ -n "$DIST_DIR" ] || { usage >&2; die "--dir is required"; }
[ -d "$DIST_DIR" ] || die "--dir '$DIST_DIR' is not a directory"
case "$VERSION" in
  ""|*[!0-9.]*|.*|*.) die "--version must be dotted digits, e.g. 0.1.29 (got '$VERSION')" ;;
esac
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then die "notes file not found: $NOTES_FILE"; fi

MANIFEST="$OUT/appcast-$VERSION.json"
SIGFILE="$OUT/appcast-$VERSION.sig"
if [ -z "$PREVIOUS" ]; then PREVIOUS="$OUT/appcast.json"; fi
if [ -n "$KEY" ] && [ ! -f "$KEY" ]; then die "key not found: $KEY"; fi

# --- Collect the artifacts. A silently skipped architecture means those users never update, --
# --- so an unrecognised one is fatal rather than a warning. ----------------------------------
ZIP_ARGS=()
for arch in arm64 x86_64 universal; do
  z="$DIST_DIR/Marquee-$VERSION-macos-$arch.zip"
  [ -f "$z" ] || continue
  ZIP_ARGS+=(--zip "$arch=$z")
done
[ "${#ZIP_ARGS[@]}" -gt 0 ] || die "no Marquee-$VERSION-macos-{arm64,x86_64,universal}.zip in $DIST_DIR"

shopt -s nullglob
for z in "$DIST_DIR/Marquee-$VERSION-macos-"*.zip; do
  base="$(basename "$z")"
  case "$base" in
    "Marquee-$VERSION-macos-arm64.zip"|"Marquee-$VERSION-macos-x86_64.zip"|"Marquee-$VERSION-macos-universal.zip") ;;
    *) die "unrecognised artifact '$base'; teach this script its arch before publishing" ;;
  esac
done
shopt -u nullglob

TMP="$(mktemp -d "${TMPDIR:-/tmp}/make-appcast.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# One python program serialises both documents, so the byte layout is defined in exactly one
# place and re-running over unchanged inputs is a no-op. Written to a temp file (rather than
# inlined twice) so both halves share it.
cat >"$TMP/appcast.py" <<'PY'
"""Deterministic appcast serializer. Invoked twice: once for the manifest, once for the .sig."""
import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import sys
from urllib.parse import urlsplit

MAX_RELEASES = 5
SUPPORTED_ARCHES = ("arm64", "x86_64", "universal")
NOTES_FALLBACK = "Maintenance release."
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    raise SystemExit(1)


def version_key(version):
    """Sort key that orders 0.1.9 below 0.1.29 (numeric components, never lexicographic).

    Pre-release suffixes follow the same rule: identifiers are compared one at a time, numerics as
    numbers and below alphanumerics, so `beta.10` sorts *above* `beta.9`. This mirrors
    `UpdateVersion.isPrereleaseOrderedBefore` in MarqueeCore exactly — if the two ever disagree, a
    published manifest orders its releases differently from the copy that reads it.
    """
    core, _, rest = str(version).partition("-")
    numbers = [int(part) if part.isdigit() else 0 for part in core.split(".")]
    numbers = (numbers + [0, 0, 0, 0])[:4]
    # A final release outranks any pre-release of the same number.
    if not rest:
        return (numbers, 1, (), 0)
    identifiers = rest.split(".")
    ordered = [(0, int(part), "") if part.isdigit() else (1, 0, part) for part in identifiers]
    return (numbers, 0, tuple(ordered), len(identifiers))


def compare_versions(left, right):
    a, b = version_key(left), version_key(right)
    return (a > b) - (a < b)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def notes_from_changelog(path, version):
    """The body of the ``## <version>`` (or ``## [<version>] - date``) section, verbatim."""
    if not os.path.isfile(path):
        sys.stderr.write("warning: no changelog at %s; using fallback notes\n" % path)
        return NOTES_FALLBACK
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    start, depth = None, 0
    for index, line in enumerate(lines):
        heading = HEADING.match(line)
        if not heading:
            continue
        if start is None:
            words = heading.group(2).split()
            if words and words[0].strip("[]") == version:
                start, depth = index + 1, len(heading.group(1))
        elif len(heading.group(1)) <= depth:
            break
    if start is None:
        sys.stderr.write("warning: no '%s' section in %s; using fallback notes\n" % (version, path))
        return NOTES_FALLBACK

    body = []
    for line in lines[start:]:
        heading = HEADING.match(line)
        if heading and len(heading.group(1)) <= depth:
            break
        body.append(line.rstrip())
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    if not body:
        sys.stderr.write("warning: '%s' section in %s is empty; using fallback notes\n"
                         % (version, path))
        return NOTES_FALLBACK
    return "\n".join(body)


def load_previous(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except ValueError as exc:
        die("previous manifest %s is not valid JSON: %s" % (path, exc))
    if not isinstance(data, dict):
        die("previous manifest %s is not a JSON object" % path)
    if "schema" in data and data["schema"] != 1:
        die("previous manifest %s uses schema %r; this script only understands schema 1"
            % (path, data["schema"]))
    return data


def validate_release(release, base_netloc, carried):
    version = release.get("version")
    where = ("carried-forward release %s" % version if carried
             else "release %s" % version)
    if not version:
        die("a carried-forward release has no version")
    if release.get("channel") not in ("beta", "stable"):
        die("%s: channel must be 'beta' or 'stable' (got %r) -- hand-edit the previous manifest "
            "or regenerate the whole feed" % (where, release.get("channel")))
    if "minimumVersion" in release and compare_versions(release["minimumVersion"], version) > 0:
        die("release %s: minimumVersion %s is newer than the release itself"
            % (version, release["minimumVersion"]))
    builds = release.get("builds") or []
    if not builds:
        die("release %s has no builds" % version)
    for build in builds:
        where = "release %s build %s" % (version, build.get("arch"))
        if build.get("arch") not in SUPPORTED_ARCHES:
            die("%s: arch must be one of %s (got %r)"
                % (where, "/".join(SUPPORTED_ARCHES), build.get("arch")))
        url = build.get("url") or ""
        parts = urlsplit(url)
        if parts.scheme != "https":
            die("%s: url must be https (%s)" % (where, url))
        if parts.netloc != base_netloc:
            die("%s: url host %r does not match --base host %r (%s)"
                % (where, parts.netloc, base_netloc, url))
        if not HEX64.match(build.get("sha256") or ""):
            die("%s: sha256 must be 64 lowercase hex characters (%r)" % (where, build.get("sha256")))
        size = build.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            die("%s: size must be a positive integer (got %r)" % (where, size))


def emit(obj, path):
    """One canonical byte layout: sorted keys, 2-space indent, UTF-8, trailing newline."""
    data = (json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)
    return data


def cmd_manifest(args):
    base = urlsplit(args.base)
    if base.scheme != "https":
        die("--base must be https (%s)" % args.base)
    if not base.netloc:
        die("--base has no host (%s)" % args.base)

    builds = []
    newest = 0.0
    for spec in args.zip:
        arch, _, path = spec.partition("=")
        size = os.path.getsize(path)
        if size <= 0:
            die("artifact %s is empty" % path)
        builds.append({
            "arch": arch,
            "url": "%s/downloads/%s" % (args.base.rstrip("/"), os.path.basename(path)),
            "sha256": sha256_file(path),
            "size": size,
            "minOS": args.min_os,
        })
        newest = max(newest, os.path.getmtime(path))

    if args.generated_at:
        generated_at = args.generated_at
    elif os.environ.get("SOURCE_DATE_EPOCH"):
        generated_at = datetime.datetime.fromtimestamp(
            int(os.environ["SOURCE_DATE_EPOCH"]), datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        generated_at = datetime.datetime.fromtimestamp(
            newest, datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.notes_file:
        with open(args.notes_file, "r", encoding="utf-8") as handle:
            notes = handle.read().strip() or NOTES_FALLBACK
    else:
        notes = notes_from_changelog(args.changelog, args.version)

    release = {
        "version": args.version,
        "channel": args.channel,
        "publishedAt": generated_at,
        "yanked": bool(args.yanked),
        "notes": notes,
        "builds": builds,
    }
    if args.minimum_version:
        release["minimumVersion"] = args.minimum_version

    previous = load_previous(args.previous) if args.previous else {}
    carried = [r for r in (previous.get("releases") or []) if isinstance(r, dict)]

    # Re-publishing the same version is how a bad build gets yanked, so it is allowed with an
    # explicit --replace. Anything not strictly older is a hard error: silently reordering a
    # signed feed is worse than stopping.
    blocking = [r.get("version") for r in carried
                if compare_versions(r.get("version"), args.version) >= 0]
    newer = [v for v in blocking if v != args.version]
    if newer:
        die("version %s is not newer than %s already in %s; bump --version"
            % (args.version, newer[0], args.previous))
    if blocking:
        if not args.replace:
            die("version %s is already in %s; pass --replace to regenerate it in place (to yank "
                "a bad build) or bump the version" % (args.version, args.previous))
        for existing in carried:
            if existing.get("version") == args.version:
                # Keep fields this run did not set (minimumVersion, hand-written notes, ...).
                for key, value in existing.items():
                    release.setdefault(key, value)
        carried = [r for r in carried if r.get("version") != args.version]

    releases = [release] + carried
    releases.sort(key=lambda r: version_key(r.get("version")), reverse=True)
    dropped = releases[MAX_RELEASES:]
    releases = releases[:MAX_RELEASES]

    for index, entry in enumerate(releases):
        validate_release(entry, base.netloc, carried=index > 0)

    manifest = dict(previous)  # unknown top-level fields survive a round trip
    manifest.update({
        "schema": 1,
        "app": args.app,
        "generatedAt": generated_at,
        "signatureURL": "%s/appcast-%s.sig" % (args.base.rstrip("/"), args.version),
        "releases": releases,
    })
    emit(manifest, args.out_manifest)

    print("appcast   %s" % args.out_manifest)
    print("  version %s  channel %s  generatedAt %s%s"
          % (args.version, args.channel, generated_at, "  YANKED" if args.yanked else ""))
    for build in builds:
        print("  %-9s %s  %d bytes  sha256 %s"
              % (build["arch"], build["url"], build["size"], build["sha256"]))
    print("  signatureURL %s" % manifest["signatureURL"])
    print("  manifest holds %d version(s), newest first: %s"
          % (len(releases), ", ".join(str(r.get("version")) for r in releases)))
    for entry in dropped:
        print("  no longer in the manifest (not offered to clients): %s" % entry.get("version"))


def cmd_sig(args):
    with open(args.manifest, "rb") as handle:
        raw = handle.read()
    with open(args.sig_bin, "rb") as handle:
        signature = handle.read()
    if len(signature) != 64:
        die("raw signature is %d bytes, expected 64" % len(signature))
    emit({
        "schema": 1,
        "keyID": args.key_id,
        "algorithm": "ed25519",
        "signedFile": os.path.basename(args.manifest),
        "signedSHA256": hashlib.sha256(raw).hexdigest(),
        "signature": base64.b64encode(signature).decode("ascii"),
    }, args.out_sig)
    print("signature %s  keyID %s  over %d bytes of %s"
          % (args.out_sig, args.key_id, len(raw), os.path.basename(args.manifest)))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    manifest = sub.add_parser("manifest")
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--base", required=True)
    manifest.add_argument("--app", required=True)
    manifest.add_argument("--channel", required=True)
    manifest.add_argument("--min-os", required=True)
    manifest.add_argument("--out-manifest", required=True)
    manifest.add_argument("--previous")
    manifest.add_argument("--changelog", required=True)
    manifest.add_argument("--notes-file")
    manifest.add_argument("--generated-at")
    manifest.add_argument("--minimum-version")
    manifest.add_argument("--yanked", action="store_true")
    manifest.add_argument("--replace", action="store_true")
    manifest.add_argument("--zip", action="append", default=[])
    manifest.set_defaults(func=cmd_manifest)

    signature = sub.add_parser("sig")
    signature.add_argument("--manifest", required=True)
    signature.add_argument("--sig-bin", required=True)
    signature.add_argument("--out-sig", required=True)
    signature.add_argument("--key-id", required=True)
    signature.set_defaults(func=cmd_sig)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
PY

mkdir -p "$OUT"

PY_ARGS=(manifest
  --version "$VERSION"
  --base "$BASE"
  --app "$APP_ID"
  --channel "$CHANNEL"
  --min-os "$MIN_OS"
  --out-manifest "$MANIFEST"
  --changelog "$CHANGELOG"
  "${ZIP_ARGS[@]}")
if [ -n "$MINIMUM_VERSION" ]; then PY_ARGS+=(--minimum-version "$MINIMUM_VERSION"); fi
if [ -n "$NOTES_FILE" ]; then PY_ARGS+=(--notes-file "$NOTES_FILE"); fi
if [ -n "$GENERATED_AT" ]; then PY_ARGS+=(--generated-at "$GENERATED_AT"); fi
if [ -f "$PREVIOUS" ]; then PY_ARGS+=(--previous "$PREVIOUS"); fi
if [ "$YANKED" = 1 ]; then PY_ARGS+=(--yanked); fi
if [ "$REPLACE" = 1 ]; then PY_ARGS+=(--replace); fi

python3 "$TMP/appcast.py" "${PY_ARGS[@]}"

if [ -z "$KEY" ]; then
  warn "no --key given: wrote an UNSIGNED manifest. The updater will refuse it; dry run only."
  exit 0
fi

openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$MANIFEST" -out "$TMP/sig.bin"
python3 "$TMP/appcast.py" sig --manifest "$MANIFEST" --sig-bin "$TMP/sig.bin" \
  --out-sig "$SIGFILE" --key-id "$KEY_ID"

# Verify against the exact bytes on disk before publishing them anywhere: a mismatch here would
# brick every install silently.
openssl pkey -in "$KEY" -pubout -out "$TMP/pub.pem" 2>/dev/null
if ! openssl pkeyutl -verify -rawin -pubin -inkey "$TMP/pub.pem" \
     -in "$MANIFEST" -sigfile "$TMP/sig.bin" >/dev/null 2>&1; then
  die "self-check failed: the signature does not verify over the bytes of $MANIFEST"
fi
echo "  verified: openssl pkeyutl -verify over the manifest bytes succeeded"
