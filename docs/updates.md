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

```
/srv/tv.guihot.net/            bind-mounted into the nginx container as the document root
  appcast.json                 symlink -> appcast-<version>.json
  appcast-<version>.json       immutable, signed
  appcast-<version>.sig        immutable detached signature
  downloads/
    Marquee-<version>-macos-arm64.zip
    Marquee-<version>-macos-x86_64.zip
    Marquee-<version>-macos-universal.zip
```

`appcast.json` is a symlink flipped with `mv -T`, which is atomic. Both versioned files are
uploaded *before* the flip, so no client can fetch a manifest and a signature from different
releases. This is why the signature is a separate file rather than a field inside the JSON: it
removes the window entirely instead of making it small.

`scripts/site/nginx/marquee-updates.conf` owns only these paths. It must not declare `server`,
`root` or `index` — it is included by whatever owns the vhost. The caching rules are not
negotiable:

| Path | `Cache-Control` | Why |
|---|---|---|
| `appcast.json` | `no-cache`, ETags off | A CDN holding the manifest means users don't see releases for hours, which is indistinguishable from "no update available" |
| `appcast-<version>.*` | `public, max-age=31536000, immutable` | Content never changes once published |
| `downloads/` | `public, max-age=31536000, immutable` | Named by release, pinned by hash |

ETags are disabled on the manifest on purpose: a `304` with no body is easy to mistake for an
empty feed, and the file is about 5 KB. Saving nothing is not worth a silent failure mode.

## Prerequisites

- DNS: an `A` record `tv` → the VPS, proxied through Cloudflare, SSL mode **Full (strict)**.
- Nginx Proxy Manager reverse-proxies `tv.guihot.net` to the container's published port.
- A `deploy` user whose `authorized_keys` entry is forced to rsync into that one directory. The
  public key goes in the `MARQUEE_DEPLOY_KEY` secret.
- `MARQUEE_KNOWN_HOSTS` secret, or a committed `scripts/site/known_hosts`. **Never**
  `StrictHostKeyChecking=no`: a silent MITM on the box that serves every update is the whole
  attack surface. `scripts/site/known_hosts.example` documents populating it.
- `MARQUEE_APPCAST_KEY_PEM` secret: the private key.
- `MARQUEE_DEPLOY_HOST` repository variable, defaulting to `85.155.188.130`.

## First-time key setup

```bash
openssl genpkey -algorithm ed25519 -out marquee-appcast.pem          # -> MARQUEE_APPCAST_KEY_PEM
openssl pkey -in marquee-appcast.pem -pubout -out marquee-appcast.pub.pem
scripts/make-appcast.sh --print-keyring --key marquee-appcast.pem --key-id marquee-2026
```

Paste the output into `AppcastKeyringMarquee.keys` in
`Sources/Marquee/Services/AppUpdater.swift`. An empty keyring switches the updater **off** rather
than letting it fail at runtime — there is no version of this that works without a real key in it.

The private key never goes in the repo. If it is ever exposed, generate a new one and follow
[Rotating the key](#rotating-the-key).

### Rotating the key

1. Generate the new key and sign manifests with it under a new `keyID`.
2. Ship a build whose keyring holds **both** keys. Every install that has not updated yet still
   verifies against the old one; dropping it locks them out permanently.
3. Publish one release signed with the old key.
4. Ship a build whose keyring holds only the new key.

## Cutting a release by hand

The release workflow does all of this. To do it manually:

```bash
scripts/bundle.sh .build/release/Marquee dist/Marquee.app 0.1.31
ditto -c -k --keepParent dist/Marquee.app dist/Marquee-0.1.31-macos-arm64.zip

# Pull the live manifest first: the feed lives only on the VPS, never in git.
scp deploy@tv.guihot.net:/srv/tv.guihot.net/appcast.json /tmp/live-appcast.json

scripts/make-appcast.sh --version 0.1.31 --dir dist --base https://tv.guihot.net \
    --out site --key marquee-appcast.pem --previous /tmp/live-appcast.json
scripts/publish-updates.sh --host 85.155.188.130 --local site
```

Release notes come from the `CHANGELOG.md` section for that version, so "What's new" in the update
sheet is whatever was written there. Without one, the app shows a generic line — which is what
`--generate-notes` was producing, and it is why the notes were empty until now.

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
  writing once signing is configured — is empty. The app is therefore held only to
  `anchor apple generic and identifier "com.danskullz.marquee"`. That still rejects an app signed
  by someone else, which is the important part, but it cannot pin *who*. Setting the team turns the
  check on with no code change.
- **Notarization.** Until builds are notarized, a downloaded Marquee will show a Gatekeeper
  prompt. That needs Developer ID first, and it should be fixed before public release.
- **Stable channel.** CI publishes every release as a prerelease and the appcast defaults to
  `beta`. At v1, publish to the `stable` channel and drop `--prerelease` from the release step.
- **Background updates.** The updater only runs while the app is open, and never over a download
  or a playing title. Silent updates while Marquee is closed need the `SMAppService` helper
  already planned in `PLAN.md`.