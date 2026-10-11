# scripts/site — deployment contract for the updater's files

Everything the in-app updater needs lives on the host at `/srv/tv.guihot.net`, served by an
`nginx:alpine` container, reverse-proxied by Nginx Proxy Manager. This directory owns **only**
the updater's HTTP contract. It deliberately does not own `index.html`, CSS, or anything else
about how the site looks.

| File | Purpose |
| --- | --- |
| `nginx/marquee-updates.conf` | `location` blocks for the manifest, the signatures and `/downloads/`. Included *inside* the `server {}` block the site config owns. |
| `known_hosts.example` | How to pin the deploy host's ssh key. Copy to `known_hosts`, fill in, commit. |
| `known_hosts` | (git-ignored, operator-created) the pinned host key that `publish-updates.sh` requires. |
| `appcast-keyring.md` | The pinned Ed25519 public key that ships inside the app. |

## The bind mount is the whole point

The document root is a **bind mount from the host**:

```
/srv/tv.guihot.net  ->  /usr/share/nginx/html   (in the nginx container)
```

`publish-updates.sh` rsyncs straight into `/srv/tv.guihot.net`. No image rebuild, no `docker
compose up`, no copy step: a release is a file landing in a directory the container is already
serving. This is also what makes the atomic pointer flip meaningful — `rename(2)` is atomic
inside the bind mount exactly as it would be on any filesystem, and nginx resolves the symlink
per request.

There is no `Dockerfile` or `docker-compose.yml` checked in here on purpose: the homepage
scaffolding owns those, and two `compose` files for one container is one too many. The shape
it needs to satisfy is:

```yaml
services:
  web:
    image: nginx:alpine
    ports: ["127.0.0.1:8081:80"]          # bound to loopback; NPM reaches it, the internet cannot
    volumes:
      - /srv/tv.guihot.net:/usr/share/nginx/html   # <- the bind mount that matters
      - ./scripts/site/nginx/marquee-updates.conf:/etc/nginx/conf.d.d/marquee-updates.conf:ro
    restart: unless-stopped
```

With the stock `nginx:alpine` image, `/etc/nginx/conf.d/*.conf` is included inside the `http`
block — so the snippet has to be `include`d from a `server {}` block that the site config
defines, not dropped into `conf.d` as-is. Either mount it under `/etc/nginx/snippets/` and
`include` it from the server block, or have the server block include the `conf.d` path.

## What this snippet is allowed to contain

`nginx/marquee-updates.conf` contains **only `location` blocks**. It must never define `server`,
`root`, `index`, `listen`, `upstream` or any other top-level directive — the site config owns
those, and two `server` blocks for one hostname is a silent, confusing startup failure
(`nginx -t` reports "duplicate server name" rather than what you changed).

It owns exactly these paths:

- `= /appcast.json` — the live manifest, a symlink to `appcast-<version>.json`
- `= /appcast.json.sig` — convenience alias for its signature
- `/appcast-<version>.json`, `/appcast-<version>.sig` — immutable, per release
- `/downloads/` — the `.zip` builds

## The `add_header` inheritance trap

nginx's `add_header` **does not merge across blocks**. From the docs: "These directives are
inherited from the previous configuration level if and only if there are no `add_header`
directives defined on the current level."

So if the parent `server` block declares `add_header X-Frame-Options ...`, and any `location`
declares its own `add_header`, the parent header silently disappears for requests hitting that
location — and it is easy to spend an afternoon on a missing security header because of a
`Cache-Control` line. That is why every `location` in `marquee-updates.conf` declares its own
headers explicitly rather than relying on inheritance.

If the site needs headers that must apply to *both* the homepage and these locations, use NPM's
per-domain **Custom Headers** field instead, or declare them in the `server` block and accept
that this snippet's locations will override. Test with
`curl -sI https://tv.guihot.net/ | grep -i '^x-'` after changing either.

## NPM passes response headers through

NPM is a reverse proxy, not a cache: it forwards upstream response headers unchanged, so the
`Cache-Control` values set here are what the client receives. Two things to confirm on the VPS
when wiring it up:

- **No CDN in front of NPM.** Any CDN that caches `/appcast.json` without revalidating makes
  updates invisible for hours — every user silently stays on an old build. If a CDN is added
  later, `/appcast.json` must be excluded or forced to revalidate.
- **`disable_symlinks` must stay `off`.** `appcast.json` is a symlink. If someone hardens the
  server block with `disable_symlinks on`, the manifest 404s and every client that cannot reach
  it must refuse to update (which is the correct failure mode, but still a broken channel).

## The updater access log

`access_log off` on the `.sig` locations keeps 64-byte requests out of the main log, but the
manifest and download fetches are the ones worth watching — they are the only evidence that
updates are reaching users at all:

```nginx
log_format updater '$time_iso8601 $remote_addr "$request" $status $body_bytes_sent '
                   'ua="$http_user_agent" ref="$http_referer"';
```

```nginx
access_log /var/log/nginx/updater.access.log updater;
```

Put that in the `server` block (it has to be in `http` for `log_format`, so the snippet above
is two separate things: the format goes at `http` level, the `access_log` at `server` level).
See [docs/updates.md](../../docs/updates.md) for what to look for in it.
