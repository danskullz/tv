#!/usr/bin/env bash
# Publishes a generated appcast and its artifacts to the update host, then flips the appcast.json
# pointer atomically. Runs from GitHub Actions or by hand.
#
#   scripts/publish-updates.sh --host 85.155.188.130 --local site
#
# Order of operations (each step depends on the one before it):
#   1. every file is rsynced to <name>.incoming, so a client never sees a partial download
#   2. all of them are mv'd into place in one remote command
#   3. appcast.json (a symlink) is re-pointed with ln -sfn + mv -T -- a single rename(2)
#   4. only then are superseded versions pruned
#
# Host keys are pinned via --known-hosts and StrictHostKeyChecking=yes, always. There is no flag
# to turn that off: the deploy key is a write credential for the update channel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/publish-updates.sh --host <85.155.188.130> [--user deploy]
                                   [--remote-root /srv/tv.guihot.net] [--known-hosts <path>]
                                   [--dry-run] [--local <site dir>] [--version <0.1.29>]
                                   [--identity <ssh key>]
  --dry-run       print the upload and prune plan, change nothing
  --local         directory holding appcast-<version>.{json,sig} (default: <repo>/site)
  --dist          directory holding the Marquee-*.zip builds (default: the same as --local)
  --version       publish this version (default: the newest appcast-<version>.json in --local)
  --identity      ssh private key (CI passes $MARQUEE_DEPLOY_KEY written to a temp file)
  --allow-shrink  publish even though this manifest offers fewer versions than the live one
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

HOST=""
USER_NAME="deploy"
REMOTE_ROOT="/srv/tv.guihot.net"
KNOWN_HOSTS="$ROOT/scripts/site/known_hosts"
DRY_RUN=0
LOCAL=""
DIST=""
VERSION=""
IDENTITY=""
ALLOW_SHRINK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST="${2:?--host needs a value}"; shift 2 ;;
    --user)         USER_NAME="${2:?--user needs a value}"; shift 2 ;;
    --remote-root)  REMOTE_ROOT="${2:?--remote-root needs a value}"; shift 2 ;;
    --known-hosts)  KNOWN_HOSTS="${2:?--known-hosts needs a value}"; shift 2 ;;
    --local)        LOCAL="${2:?--local needs a value}"; shift 2 ;;
    --dist)         DIST="${2:?--dist needs a value}"; shift 2 ;;
    --version)      VERSION="${2:?--version needs a value}"; shift 2 ;;
    --identity)     IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --allow-shrink) ALLOW_SHRINK=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; die "--host is required"; }
[ -n "$LOCAL" ] || LOCAL="$ROOT/site"
[ -d "$LOCAL" ] || die "--local '$LOCAL' is not a directory"
# The manifest and its signature travel together; the .zip builds usually sit in the packaging
# directory instead, which is what --dist is for (CI generates into site/ and builds into dist/).
[ -n "$DIST" ] || DIST="$LOCAL"
[ -d "$DIST" ] || die "--dist '$DIST' is not a directory"

# Everything remote is built from these three, so they are validated before reaching a shell.
case "$HOST" in
  *[!A-Za-z0-9.:@-]*) die "--host has characters that are unsafe in an ssh target: $HOST" ;;
esac
case "$USER_NAME" in
  *[!A-Za-z0-9._-]*) die "--user has unsafe characters: $USER_NAME" ;;
esac
case "$REMOTE_ROOT" in
  /*) ;;
  *) die "--remote-root must be an absolute path: $REMOTE_ROOT" ;;
esac
case "$REMOTE_ROOT" in
  *[!A-Za-z0-9._/-]*) die "--remote-root has unsafe characters: $REMOTE_ROOT" ;;
esac

command -v ssh >/dev/null 2>&1 || die "ssh is required but not installed"
command -v rsync >/dev/null 2>&1 || die "rsync is required but not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required but not installed"

# --- Pinned host keys. No override, on purpose. ----------------------------------------------
if [ ! -f "$KNOWN_HOSTS" ]; then
  cat >&2 <<EOF
error: known-hosts file not found: $KNOWN_HOSTS
       The deploy host key must be pinned before anything is published. Create it once with
         ssh-keyscan -H $HOST > $KNOWN_HOSTS
       then check the fingerprint it prints against the one shown in the provider's console
       (out of band -- a keyscan alone proves nothing) and commit the verified file.
       See scripts/site/known_hosts.example.
EOF
  exit 1
fi
if ! grep -qF "$HOST" "$KNOWN_HOSTS"; then
  die "no pinned key for $HOST in $KNOWN_HOSTS -- add it with 'ssh-keyscan $HOST', verify the
       fingerprint out of band, and retry. Refusing to fall back to StrictHostKeyChecking=no"
fi
case "$KNOWN_HOSTS" in
  *[[:space:]]*) die "--known-hosts path contains whitespace, which ssh would split: $KNOWN_HOSTS" ;;
esac
if [ -n "$IDENTITY" ]; then
  [ -f "$IDENTITY" ] || die "ssh identity not found: $IDENTITY"
  chmod 0600 "$IDENTITY" 2>/dev/null || true
fi

# --- SSH options. Word splitting is intended: rsync and ssh take these as separate arguments. -
# shellcheck disable=SC2086
SSH_OPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o BatchMode=yes -o ConnectTimeout=15"
if [ -n "$IDENTITY" ]; then
  # shellcheck disable=SC2086
  SSH_OPTS="$SSH_OPTS -o IdentitiesOnly=yes -i $IDENTITY"
fi
TARGET="$USER_NAME@$HOST"

remote_run() {
  # The argument is a complete command for the remote shell (mv/ln/rm/ls), assembled here from
  # validated components. SC2029 is the remote shell re-parsing it, which is the point.
  # shellcheck disable=SC2086,SC2029
  ssh $SSH_OPTS "$TARGET" "$@"
}
rsync_run() {
  # shellcheck disable=SC2086
  rsync -a --partial --itemize-changes -e "ssh $SSH_OPTS" "$@"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-updates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# --- Read the local manifest: which release to publish, its builds, and every version the
# --- manifest still offers (the prune allow-list). Prints "<version> <manifest> <sig>" on
# --- stdout and writes the build list and the version allow-list for the shell to use. --------
python3 - "$LOCAL" "$VERSION" "$TMP" >"$TMP/plan" <<'PY'
"""Chooses the release to publish; writes the artifacts and the prune allow-list into $TMP."""
import glob
import json
import os
import re
import sys

local, want_version, tmp = sys.argv[1:4]
MANIFEST_RE = re.compile(r"^appcast-(\d+(?:\.\d+)+)\.json$")


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    raise SystemExit(1)


def version_key(version):
    core, _, rest = version.partition("-")
    numbers = [int(part) if part.isdigit() else 0 for part in core.split(".")]
    return ((numbers + [0, 0, 0, 0])[:4], 0 if rest else 1, rest)


candidates = {}
for path in glob.glob(os.path.join(local, "appcast-*.json")):
    found = MANIFEST_RE.match(os.path.basename(path))
    if found:
        candidates[found.group(1)] = path
if not candidates:
    die("no appcast-<version>.json in %s; run scripts/make-appcast.sh first" % local)

if want_version:
    if want_version not in candidates:
        die("no appcast-%s.json in %s" % (want_version, local))
    version = want_version
else:
    # Newest by version number, not mtime: CI regenerates files and mtime would lie.
    version = max(candidates, key=version_key)
manifest_path = candidates[version]

sig_path = os.path.join(local, "appcast-%s.sig" % version)
if not os.path.isfile(sig_path):
    die("missing %s -- an unsigned manifest is refused by every client" % sig_path)

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("schema") != 1:
    die("%s has schema %r, expected 1" % (manifest_path, manifest.get("schema")))
if not str(manifest.get("signatureURL", "")).endswith("appcast-%s.sig" % version):
    die("%s signatureURL %r does not point at appcast-%s.sig"
        % (manifest_path, manifest.get("signatureURL"), version))

releases = manifest.get("releases") or []
entry = next((r for r in releases if r.get("version") == version), None)
if entry is None:
    die("%s does not list release %s" % (manifest_path, version))
if not entry.get("builds"):
    die("release %s in %s has no builds" % (version, manifest_path))

with open(os.path.join(tmp, "versions"), "w", encoding="utf-8") as handle:
    for release in releases:
        handle.write("%s\n" % release.get("version"))

with open(os.path.join(tmp, "builds"), "w", encoding="utf-8") as handle:
    for build in entry["builds"]:
        name = str(build.get("url", "")).rsplit("/", 1)[-1]
        if not name.endswith(".zip"):
            die("release %s: build url %r does not end in .zip" % (version, build.get("url")))
        handle.write("%s\t%s\n" % (name, build.get("sha256") or ""))

sys.stdout.write("%s\n%s\n%s\n" % (version, manifest_path, sig_path))
PY
VERSION="$(sed -n 1p "$TMP/plan")"
MANIFEST_PATH="$(sed -n 2p "$TMP/plan")"
SIG_PATH="$(sed -n 3p "$TMP/plan")"
[ -n "$VERSION" ] || die "could not determine which version to publish"
[ -f "$SIG_PATH" ] || die "missing signature $SIG_PATH"
[ -s "$TMP/builds" ] || die "manifest lists no downloadable builds for $VERSION"

echo "publishing $VERSION to $TARGET:$REMOTE_ROOT"
echo "  manifest  $MANIFEST_PATH"
echo "  signature $SIG_PATH"

# --- Pre-flight: every artifact the manifest promises must exist locally and match it. -------
# Publishing a manifest that disagrees with its own bytes breaks every verifying client.
# The table is "<local source> <remote path> <label>", one line per file to transfer.
UPLOAD_LINES="$TMP/uploads"
: >"$UPLOAD_LINES"
printf '%s\t%s\t%s\n' "$MANIFEST_PATH" "$(basename "$MANIFEST_PATH")" "$(basename "$MANIFEST_PATH")" >>"$UPLOAD_LINES"
printf '%s\t%s\t%s\n' "$SIG_PATH" "$(basename "$SIG_PATH")" "$(basename "$SIG_PATH")" >>"$UPLOAD_LINES"
while IFS=$'\t' read -r name sha; do
  [ -n "$name" ] || continue
  path="$DIST/$name"
  [ -f "$path" ] || die "the manifest lists $name but $path does not exist (--local $LOCAL,
       --dist $DIST); rebuild it or point --dist at the packaging directory"
  actual="$(sha256_of "$path")"
  [ "$actual" = "$sha" ] || die "$name does not match the manifest (manifest $sha, file $actual)
       -- regenerate with scripts/make-appcast.sh before publishing"
  printf '%s\t%s\t%s\n' "$path" "downloads/$name" "$name" >>"$UPLOAD_LINES"
done <"$TMP/builds"

# --- Plan ------------------------------------------------------------------------------------
echo
echo "plan:"
while IFS=$'\t' read -r source remote label; do
  [ -n "$source" ] || continue
  echo "  upload  $label -> $remote"
done <"$UPLOAD_LINES"

# --- Prune plan: remote files whose version the manifest no longer offers. -------------------
in_manifest() {
  local candidate="$1" kept
  while read -r kept; do
    if [ "$kept" = "$candidate" ]; then return 0; fi
  done <"$TMP/versions"
  return 1
}

version_of_appcast() { basename "$1" | sed -n 's/^appcast-\([0-9][0-9.]*\)\.json$/\1/p'; }
version_of_sig()      { basename "$1" | sed -n 's/^appcast-\([0-9][0-9.]*\)\.sig$/\1/p'; }
version_of_zip()      { basename "$1" | sed -n 's/^Marquee-\([0-9][0-9.]*\)-macos-.*\.zip$/\1/p'; }

PRUNE="$TMP/prune"
: >"$PRUNE"
REMOTE_LISTING="$TMP/remote"
if remote_run "ls -1 '$REMOTE_ROOT' 2>/dev/null; echo --; ls -1 '$REMOTE_ROOT/downloads' 2>/dev/null" \
     >"$REMOTE_LISTING" 2>"$TMP/ssh.err"; then
  in_downloads=0
  while read -r line; do
    if [ "$line" = "--" ]; then in_downloads=1; continue; fi
    [ -n "$line" ] || continue
    if [ "$in_downloads" = 1 ]; then
      path="downloads/$line"
      found="$(version_of_zip "$line")"
    else
      path="$line"
      found="$(version_of_appcast "$line")"
      if [ -z "$found" ]; then found="$(version_of_sig "$line")"; fi
    fi
    [ -n "$found" ] || continue
    if in_manifest "$found"; then continue; fi   # never touch a version the manifest offers
    printf '%s\t%s\n' "$path" "$found" >>"$PRUNE"
  done <"$REMOTE_LISTING"
else
  echo "warning: could not list $REMOTE_ROOT over ssh:" >&2
  sed 's/^/  /' "$TMP/ssh.err" >&2
  if [ "$DRY_RUN" = 1 ]; then
    echo "warning: the prune list below is empty because the host is unreachable" >&2
  else
    die "cannot list the remote root; refusing to publish blind"
  fi
fi

echo "  pointer $(basename "$MANIFEST_PATH") -> appcast.json   (symlink, renamed last)"
if [ -s "$PRUNE" ]; then
  echo "  prune:"
  while IFS=$'\t' read -r path v; do
    [ -n "$path" ] || continue
    echo "    delete $path  (version $v is not in the manifest)"
  done <"$PRUNE"
else
  echo "  prune: nothing to delete"
fi

# --- Shrink guard ---------------------------------------------------------------------------
# The manifest decides what is offered *and* what may be deleted. A manifest built without the
# live appcast.json in --local carries only the new release, which would quietly stop offering
# the four previous versions and delete their downloads. Refuse before touching anything.
OFFERED="$(grep -c . <"$TMP/versions")"
LIVE=0
if remote_run "cat '$REMOTE_ROOT/appcast.json' 2>/dev/null" >"$TMP/live.json" 2>/dev/null; then
  LIVE="$(python3 - "$TMP/live.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(len(json.load(handle).get("releases") or []))
except Exception:
    print(0)
PY
)"
fi
if [ "$LIVE" -gt "$OFFERED" ] && [ "$ALLOW_SHRINK" = 0 ]; then
  die "this manifest offers $OFFERED version(s) but the live appcast.json offers $LIVE: the older
       releases would stop being offered and their downloads would be deleted. Generate it with
       scripts/make-appcast.sh from a --local directory that holds the live appcast.json (it
       carries earlier releases forward), or pass --allow-shrink if that is genuinely intended."
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "dry run: nothing was uploaded, moved, pointed at or deleted."
  exit 0
fi

# --- Upload: rsync writes <name>.incoming, so nothing is visible under its real name yet. -----
remote_run "mkdir -p '$REMOTE_ROOT/downloads'" || die "cannot create $REMOTE_ROOT/downloads"

echo
echo "uploading:"
while IFS=$'\t' read -r source remote label; do
  [ -n "$source" ] || continue
  [ -f "$source" ] || die "$source disappeared between the pre-flight check and now"
  rsync_run "$source" "$TARGET:$REMOTE_ROOT/$remote.incoming" || die "rsync of $label failed"
  echo "  $label -> $remote.incoming"
done <"$UPLOAD_LINES"

# --- Move everything into place in one remote command, then flip the pointer. ----------------
MOVES="set -e"
while IFS=$'\t' read -r source remote label; do
  [ -n "$source" ] || continue
  MOVES="$MOVES
mv -f '$REMOTE_ROOT/$remote.incoming' '$REMOTE_ROOT/$remote'
chmod 0644 '$REMOTE_ROOT/$remote'"
done <"$UPLOAD_LINES"
remote_run "$MOVES" || die "failed to move the uploaded files into place"
echo "  every uploaded file is now in place"

POINTER_TARGET="$(basename "$MANIFEST_PATH")"
SIG_TARGET="$(basename "$SIG_PATH")"
# appcast.json is authoritative; appcast.json.sig is a convenience alias that no client is
# required to use (it reads signatureURL from the manifest). Two renames, not one: if the second
# fails the feed is still correct, because the versioned .sig is what actually gets verified.
remote_run "set -e
ln -sfn '$POINTER_TARGET' '$REMOTE_ROOT/appcast.json.incoming'
mv -T '$REMOTE_ROOT/appcast.json.incoming' '$REMOTE_ROOT/appcast.json'
ln -sfn '$SIG_TARGET' '$REMOTE_ROOT/appcast.json.sig.incoming'
mv -T '$REMOTE_ROOT/appcast.json.sig.incoming' '$REMOTE_ROOT/appcast.json.sig'" \
  || die "failed to flip the appcast.json pointer"
echo "  appcast.json -> $POINTER_TARGET"

# --- Prune, one explicit path at a time, re-checked against the allow-list. -------------------
if [ -s "$PRUNE" ]; then
  echo "pruning:"
  while IFS=$'\t' read -r path v; do
    [ -n "$path" ] || continue
    if in_manifest "$v"; then
      echo "  SKIP $path: version $v is still in the manifest"
      continue
    fi
    if remote_run "rm -f -- '$REMOTE_ROOT/$path'"; then
      echo "  deleted $path"
    else
      echo "  warning: could not delete $path" >&2
    fi
  done <"$PRUNE"
fi

# --- Post-flight: the pointer must resolve to the file just published. ------------------------
REMOTE_STATE="$(remote_run "readlink '$REMOTE_ROOT/appcast.json'; head -c 1 '$REMOTE_ROOT/appcast.json'")" \
  || die "appcast.json does not resolve on the host"
echo
echo "remote state:"
echo "  appcast.json -> $(printf '%s' "$REMOTE_STATE" | sed -n 1p)"
case "$(printf '%s' "$REMOTE_STATE" | sed -n 2p)" in
  '{') echo "  the pointer resolves to the published manifest" ;;
  *)   die "the pointer did not resolve to a JSON manifest" ;;
esac
echo
echo "published $VERSION. Check it end to end with:"
echo "  curl -sI https://tv.guihot.net/appcast.json | grep -i cache-control"
echo "  curl -s https://tv.guihot.net/appcast.json | head -c 200"
echo "  tail -f /var/log/nginx/updater.access.log"
