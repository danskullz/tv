# In-app updates

Marquee updates itself from a signed manifest on its own website. This is the operator's guide:
what has to be true for an update to reach a user, how to cut one, and how to withdraw one.

Scope note: the app-facing API is documented at the top of
`Sources/MarqueeCore/Updates/`. This file is for whoever is holding the keys.

## The trust chain

Four gates, in order. A build that fails any of them is never installed, and the failure is
reported to the user rather than swallowed.

1. **Manifest signature.** `appcast.json` is signed with an Ed25519 key whose *public* half is
   compiled into the app (`AppcastKeyringMarquee`). The private half exists only as the
   `MARQUEE_APPCAST_KEY_PEM` GitHub secret. This is the gate that matters: the manifest and the
   binaries are served by the same host, so if it can be forged, arbitrary code can be shipped to
   every install. It fails closed — there is no "warn and continue" path.
2. **Content hash.** Each build's SHA-256 is inside the signed manifest. A tampered or corrupted
   archive is discarded.
3. **Bundle identity.** The unpacked `.app` must report the expected bundle identifier and the
   version the manifest claims. Catches a wrong or truncated archive.
4. **Code signature.** Once Developer ID is wired up, the app is checked against
   `anchor apple generic and identifier "com.danskullz.marquee" and certificate leaf[subject.OU] =
   "<team>"`. **Every build is ad-hoc signed today**, so this is currently checked for structural
   integrity only — see [Not done yet](#not-done-yet).

Because gates 1 and 2 are cryptographic and the key is not on the server, moving the zips
(GitHub Releases → the update host → anywhere else) does not weaken anything. The manifest pins
content, not location.

## Layout on the update host

VPS `85.155.188.130` (the `saturn` ssh host). Three moving parts:

| What | Where |
|---|---|
| Web root (served) | `/home/dan/www/tv.guihot.net/` |
| Signing key (private) | `/home/dan/.marquee/appcast-key.pem`, mode 600, never inside the web root |
| Site container | `/home/dan/docker/marquee-updates/` (`docker compose up -d`) |
| CI deploy key (private) | `/home/dan/.marquee/deploy_key`, mode 600 |
| NPM config for this domain | `/data/nginx/custom/http_top.conf` inside the `npm` container |
| Certificate | `/home/dan/docker/npm/letsencrypt/live/tv.guihot.net/` |

```
/home/dan/www/tv.guihot.net/   bind-mounted as the container's document root
  appcast.json                 symlink -> appcast-<version>.json
  appcast-<version>.json       immutable, signed
  appcast-<version>.sig        immutable detached signature
  .well-known/acme-challenge/  ACME HTTP-01 webroot, shared with certbot
  downloads/
    Marquee-<version>-macos-arm64.zip
    Marquee-<version>-macos-x86_64.zip
    Marquee-<version>-macos-universal.zip
```

`appcast.json` is a symlink flipped with `mv -T`, which is atomic. Both versioned files are
uploaded *before* the flip, so no client can fetch a manifest and a signature from different
releases. This is why the signature is a separate file rather than a field inside the JSON: it
removes the window entirely instead of making it small.

## TLS: how this host is actually wired

This is deliberately **not** an Nginx Proxy Manager Proxy Host. Creating one needs NPM admin
credentials, and this was deployed without them. Instead a single `server` block pair lives in
`/data/nginx/custom/http_top.conf` — NPM's documented include point, inside `http {}` — which claims
exactly one hostname and changes nothing else on the box. The live copy is version-controlled at
[`scripts/site/nginx/tv-guihot-net.conf`](../scripts/site/nginx/tv-guihot-net.conf) and deployed with:

```bash
docker cp tv-guihot-net.conf npm:/data/nginx/custom/http_top.conf
docker exec npm nginx -t && docker exec npm nginx -s reload
```

Always `nginx -t` first. A malformed file in that include takes down every other domain this box
serves — mail, git, Matrix and more.

The `marquee-updates` container serves the files over the shared `edge` network. NPM terminates TLS
and proxies to it, so publishing a release never needs a container or image restart.

### Caching

Not negotiable:

| Path | `Cache-Control` | Why |
|---|---|---|
| `appcast.json` | `no-cache`, ETags off | A CDN holding the manifest means users don't see releases for hours, which is indistinguishable from "no update available" |
| `appcast-<version>.*` | `public, max-age=31536000, immutable` | Content never changes once published |
| `downloads/` | `public, max-age=31536000, immutable` | Named by release, pinned by hash |

ETags are disabled on the manifest on purpose: a `304` with no body is easy to mistake for an empty
feed and silently stops updates. The file is about 1 KB; saving nothing is not worth that failure
mode.

### Certificate renewal

Certbot runs in a container because it needs the shared ACME webroot that NPM proxies. Cron runs
`/home/dan/.marquee/renew-cert.sh` twice daily at 03:17 and 15:17; certbot only acts inside the last
30 days of validity. Two of that script's flags are load-bearing, and both were bugs:

- **`--cert-name tv.guihot.net`** — NPM keeps its own certificates in the same directory. Without
  this, certbot also tries to renew `npm-*.conf`, which hangs indefinitely and would fight NPM for
  those certificates.
- **`--no-random-sleep-on-renew`** — certbot otherwise sleeps a random ~7 minutes before renewing,
  which is indistinguishable from a hung job.

Check changes with a dry run before trusting the cron:

```bash
docker run --rm -v /home/dan/www/tv.guihot.net:/var/www/certbot \
  -v /home/dan/docker/npm/letsencrypt:/etc/letsencrypt \
  certbot/certbot renew --cert-name tv.guihot.net --no-random-sleep-on-renew --dry-run --no-eff-email
```

### Deploy key

The CI key is `dan`'s own SSH key with a forced command, so it can only rsync:

```
command="rsync --server -logDtpre.iLsfxCvu . /home/dan/www/tv.guihot.net/",\
 no-agent-forwarding,no-port-forwarding,no-pty,no-X11-forwarding ssh-ed25519 AAAA… marquee-ci-deploy
```

Verified: it can rsync into the site, and both an interactive shell and a write outside the site
directory are refused — sshd runs the forced `rsync` instead, which fails against a non-rsync
session. To rotate, generate a new key, replace that line, then update `MARQUEE_DEPLOY_KEY`.

`StrictHostKeyChecking` is never disabled. `scripts/site/known_hosts` is committed for exactly this
reason: a silent MITM on the box that serves every update is the whole attack surface.

## Publishing

- **Automatic**: `release.yml` generates and deploys after the GitHub Release. Secrets are
  `MARQUEE_APPCAST_KEY_PEM`, `MARQUEE_DEPLOY_KEY`, `MARQUEE_KNOWN_HOSTS`; `MARQUEE_DEPLOY_HOST`
  is a repository variable. Deploy failures are `continue-on-error` so a red X never buries a real
  break, and the generated manifest is left as a workflow artifact.
- **By hand**:

```bash
scp saturn:/home/dan/www/tv.guihot.net/appcast.json /tmp/live-appcast.json   # the feed is not in git
scripts/make-appcast.sh --version 0.1.31 --dir dist --base https://tv.guihot.net \
    --out site --key marquee-appcast.pem --previous /tmp/live-appcast.json
scripts/publish-updates.sh --host 85.155.188.130 --local site
```

Release notes come from the `CHANGELOG.md` section for that version, so "What's new" in the update
sheet is whatever was written there.

## Rotating the signing key

1. Generate the new key and sign manifests with it under a new `keyID`:

   ```bash
   openssl genpkey -algorithm ed25519 -out new.pem
   scripts/make-appcast.sh --print-keyring --key new.pem --key-id marquee-2027
   ```

2. Ship a build whose keyring holds **both** keys. Every install that has not updated yet still
   verifies against the old one; dropping it locks them out permanently — they have no way to get a
   build containing the new one.
3. Publish one release signed with the old key.
4. Ship a build whose keyring holds only the new key.

The private key never goes in the repo. It is the `MARQUEE_APPCAST_KEY_PEM` secret; a working copy
lives at `/home/dan/.marquee/appcast-key.pem`.


## Withdrawing a bad build

1. Set `"yanked": true` on the release and redeploy.

```bash
scripts/make-appcast.sh --version 0.1.31 --dir dist --base https://tv.guihot.net \
    --out site --key marquee-appcast.pem --yanked
scripts/publish-updates.sh --host 85.155.188.130 --local site
```

Yanked releases disappear from the feed immediately. The files stay where they are, so anyone
already mid-download still finishes rather than getting a 404.

For something actively harmful, delete the build files and rotate the key — the manifest is the
thing that has to stop being trusted, and removing it from the feed only stops *future* installs.

## Pruning

The manifest holds the **last 5 versions**. Files for versions still in the manifest are never
deleted; everything older is. Each release is about 57 MB across the three architectures, so steady
state is roughly 285 MB.

`publish-updates.sh --dry-run` prints exactly what it would delete before deleting anything.

## Diagnosing "nobody got the update"

- `appcast.json` — check its `Cache-Control`. This is the usual cause.
- `~/Library/Application Support/Marquee/Updates/install.log` on an affected Mac — the installer
  appends every step, including a rollback.
- The nginx access log is a separate stream for these paths, so update traffic can be separated
  from the marketing site's.
- An install that rolled back left `Previous.app` next to the staged build. It is kept until the
  replacement is proven to launch.

## Not done yet

- **Developer ID signing.** Every build is ad-hoc signed, so `AppInfo.developerTeamIdentifier` —
  read from the reserved `MarqueeDeveloperTeamIdentifier` Info.plist key that `bundle.sh` will start
  writing once signing is configured — is empty. The installer therefore passes **no** pinned
  requirement, and only checks that the signature is structurally valid. It deliberately does *not*
  use `anchor apple generic`, which needs a real Developer ID and would reject every build we
  actually ship, leaving the updater permanently inert; integrity comes from the signed manifest's
  SHA-256 instead. Setting the team switches the strict rule on with no code change.
- **Notarization.** Until builds are notarized, a downloaded Marquee will show a Gatekeeper
  prompt. That needs Developer ID first, and it should be fixed before public release.
- **Stable channel.** CI publishes every release as a prerelease and the appcast defaults to
  `beta`. At v1, publish to the `stable` channel and drop `--prerelease` from the release step.
- **Background updates.** The updater only runs while the app is open, and never over a download
  or a playing title. Silent updates while Marquee is closed need the `SMAppService` helper
  already planned in `PLAN.md`.