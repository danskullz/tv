# Marquee — Project Scope

*Working title. A native macOS app that unifies the \*arr suite (Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Overseerr-style discovery) with a built-in torrent engine and a player that can start watching a release within seconds while it downloads to disk.*

Date: 2026-10-09 · Status: Draft v1

---

## 1. Vision & principles

**One sentence:** Find something, press Play, watch it in seconds, and have it end up perfectly named and organized in your library — with no config files, no browser tabs, no five-app stack.

**Principles**

1. **Play is the primary verb.** Every screen leads to one big Play button. Downloading, upgrading, subtitling and organizing are things that happen *because* you pressed Play or Add, not chores you manage.
2. **Zero-to-watching in under 5 minutes.** A first-run wizard replaces the usual hours of Docker, API keys, quality profile and path wrangling.
3. **Native or nothing.** SwiftUI/AppKit, Metal rendering, system media keys, Now Playing, AirPlay, PiP, Spotlight, Shortcuts, Handoff. It should feel like an Apple app that shipped with the OS.
4. **Opinionated defaults, deep overrides.** Smart presets for 95% of users; full Sonarr-class control (custom formats, scoring, delay profiles) behind "Advanced".
5. **Never lose data, never surprise the user.** Atomic imports, reversible actions, clear explanations for every automated decision ("Why was this release picked?").
6. **Fast everywhere.** Instant search, 120 fps scrolling, no spinners for local data, background work never blocks UI.
7. **Lightweight and fast by construction.** Native Swift only (no Electron/WebView shells, no bundled runtimes), a small dependency list that must justify itself, a small download, and near-zero idle cost. The helper daemon sleeps when nothing is happening and the UI holds no more data than is on screen. Every feature is weighed against its footprint; performance budgets (§5.6) are release gates, not goals.
8. **Content-agnostic tooling.** Like qBittorrent, Prowlarr or VLC, the app ships no content, no indexers and no trackers. Users supply their own sources. (See §14.)

---

## 2. Scope at a glance

| Area | In scope (v1) | Later | Out of scope |
|---|---|---|---|
| TV (Sonarr) | Full | | |
| Movies (Radarr) | Full | | |
| Indexers (Prowlarr) | Torznab, Cardigann-style definitions, RSS | Newznab/Usenet | Bundled indexers |
| Subtitles (Bazarr) | Search, auto-download, sync, embedded track extraction | AI translation | |
| Discovery/Requests (Overseerr) | Discover, trending, watchlist, personal "want" list | Multi-user requests | Public web portal |
| Music (Lidarr) | | v1.5 | |
| Books (Readarr) | | | Project retired upstream |
| Torrent engine | Built in (libtorrent) | | External-client-only mode as default |
| Streaming | Sequential/deadline streaming while downloading | | |
| Player | Built in (libmpv + AVPlayer paths) | | |
| Usenet | | v2 | |
| Companion apps | | iPhone/iPad/Apple TV (v2) | Android/Windows |
| Remote access / server mode | | Headless daemon + web UI (v2) | |

---

## 3. Target platform & stack

- **Target:** macOS 26 (Tahoe) primary, with a deployment target of macOS 15 where Liquid Glass APIs degrade gracefully. Universal binary (Apple Silicon + Intel), both first-class.
- **Language/UI:** Swift 6 (strict concurrency), SwiftUI for ~90% of UI, AppKit bridges for the player surface, custom grids, window chrome and drag/drop.
- **Persistence:** SQLite via GRDB (WAL mode), versioned migrations, FTS5 for library search. Image cache on disk with memory tier.
- **Torrent engine:** libtorrent-rasterbar 2.x (C++), wrapped with Swift C++ interop in a separate **background helper** (a login-item daemon registered with `SMAppService`, talking to the app over XPC). Downloads continue when the UI is closed.
- **Playback:** two paths behind one `PlaybackEngine` protocol.
  - **libmpv** (Metal/`render API`) for universal format support: MKV, HEVC/AV1, DTS/TrueHD/Atmos passthrough, PGS/ASS subtitles, HDR10 tone-mapping.
  - **AVPlayer** fast path for MP4/HLS-compatible media (native HDR10/Dolby Vision, AirPlay 2, PiP, spatial audio), including an on-the-fly **remux-to-fMP4/HLS** (bundled ffmpeg/libav, stream-copy, no re-encode) when the source is compatible once repackaged.
- **Streaming bridge:** loopback-only HTTP server in the helper with HTTP Range support, per-session random token, mapping byte ranges → torrent pieces.
- **Networking:** `URLSession` + `async/await`, HTTP/2, aggressive caching with ETags, rate-limited per-indexer queues with exponential backoff.
- **Metadata:** TMDB (primary), TheTVDB (episode ordering parity with Sonarr), Trakt (watch state/lists, optional), MusicBrainz (later), OpenSubtitles + other providers for subtitles.
- **Distribution:** Developer ID-signed, notarized, hardened runtime, Sparkle for updates. GitHub Actions builds arm64, x86_64 and universal artifacts and publishes a GitHub Release on every push to `main`. Not planned for Mac App Store (sandbox constraints on helper daemons, folder access and torrent networking; revisit later).
- **Testing/CI:** Swift Testing + XCTest UI tests, snapshot tests, GitHub Actions on macOS runners, fixture swarm (local tracker + seeders) for end-to-end tests.

### Architecture

```
┌───────────────────────── Marquee.app (SwiftUI) ─────────────────────────┐
│ Views  ←  ViewModels (@Observable)  ←  Domain services (actors)         │
│  Library · Discover · Player · Activity · Calendar · Settings           │
└───────────────┬───────────────────────────────────────┬─────────────────┘
                │ GRDB (shared SQLite, WAL)              │ XPC
┌───────────────▼──────────────┐         ┌───────────────▼─────────────────┐
│ Core library (Swift package) │         │ MarqueeHelper (login item)      │
│ Metadata · Monitoring ·      │         │ libtorrent session · piece      │
│ Release parser · Scoring ·   │         │ scheduler · stream HTTP server  │
│ Importer · Renamer · Subs    │         │ · disk I/O · VPN binding        │
└──────────────────────────────┘         └─────────────────────────────────┘
```

Core logic lives in a UI-free Swift package (`MarqueeCore`) so it's unit-testable and later reusable by a headless server and iOS/tvOS apps.

---

## 4. Feature specification

### 4.1 Library (Sonarr + Radarr, unified)

- **Single unified library** of Movies and Series, with filters (Movies / TV / Anime / Music), no separate apps.
- **Add flow:** search → pick title → choose quality preset, root folder, monitoring mode → done. One keyboard-driven sheet (`⌘N`), with smart defaults remembered per media type.
- **Monitoring modes (TV):** all, future only, first season, latest season, pilot only, specific seasons/episodes, none. Per-episode monitor toggles. **Movies:** monitor, availability trigger (announced / in cinemas / released / digital release).
- **Episode ordering:** aired, DVD, absolute (anime), alternate TVDB orders; scene numbering/mapping tables for absolute/scene mismatches.
- **Series types:** standard, daily/date-based, anime (absolute numbering, fansub release groups, batch releases).
- **Release automation:** RSS sync on interval + on-demand search; interactive search with full release table (seeders, size, age, indexer, score, rejection reasons).
- **Quality system:**
  - Presets: *Efficient (1080p, small)*, *Balanced*, *Best (2160p HDR + lossless audio)*, *Anime*, *Remux*.
  - Full quality profiles: ordered tiers, upgrade-until cutoff, minimum custom-format score.
  - **Custom formats** with a visual rule builder (codec, source, group, language, HDR type, regex), scoring, import/export, and importable community profile bundles (e.g. TRaSH-style) as JSON.
  - **Delay profiles** (wait N hours for better release), preferred protocol, release-group preferences, size limits per runtime (MB/min).
  - "**Why this release?**" panel for every grab and every rejection.
- **Upgrades:** automatic upgrade when a better-scoring release appears; safe replace (new file verified before old file removed to Trash, never permanently deleted).
- **Import & organize:**
  - Atomic move/**APFS clone**/hardlink/copy options (clonefile by default when on same volume so seeding keeps working with zero extra space).
  - Fully templated renaming with live preview (Plex/Jellyfin/Emby-compatible default naming), colon/illegal-char handling, multi-episode files.
  - Extras/sample/junk detection, archive extraction (rar/zip/7z) in a sandboxed step, mediainfo (via ffprobe) verification (runtime, duration sanity, codec match vs. claimed release).
  - Optional post-import actions: notify, trigger Plex/Jellyfin/Emby library scan, run script, Shortcut.
- **Existing library import:** point at a folder → fuzzy match to TMDB/TVDB with a review UI (confidence bars, one-click fix), "adopt in place" without moving files.
- **Migration from existing arr stack:** import from Sonarr/Radarr/Prowlarr/Bazarr via their APIs (series, profiles, custom formats, indexers, root folders, history, blocklist).
- **Connect mode (optional):** instead of standalone, point Marquee at an existing Sonarr/Radarr/Prowlarr/qBittorrent and use it purely as a front end. Same UI, remote engine. This is also the safest on-ramp for current arr users.
- **Calendar:** month/week/agenda, upcoming releases, "air tonight", iCal feed export, EventKit integration (opt-in).
- **History, blocklist, wanted/missing, cutoff unmet** — presented as smart filters rather than separate admin pages.
- **Health center:** one inbox for problems (indexer failing, disk nearly full, VPN dropped, path missing, hash fail), each with a one-click fix.

### 4.2 Discover (Overseerr-style, single-user)

- Trending, popular, new releases, upcoming, by genre/network/studio/streaming provider, "because you watched…", recently added.
- Rich title pages: hero art, trailer (in-app, via TMDB/YouTube links when available), cast/crew with filmographies, ratings (TMDB/IMDb/Rotten Tomatoes where licensed), where it's legally streaming (TMDB watch providers), collections, similar titles, seasons/episodes with stills.
- **Watchlist** (local + optional Trakt sync). "Want it" = add + monitor with a single tap.
- Global search (`⌘K`-style command palette): titles, people, library, actions, settings — fuzzy, typo-tolerant, instant.

### 4.3 Indexers (Prowlarr, integrated)

- Torznab/Newznab-compatible endpoints plus **Cardigann-format indexer definitions** (YAML), with a definition browser and auto-updating definitions repository (user-configurable source).
- Per-indexer: priority, categories, minimum seeders, rate limits, tags, proxy/FlareSolverr-style challenge solver integration (optional, user-supplied).
- Parallel search with result deduplication, canonical release parsing, health/latency stats, auto-disable on repeated failure with notification.
- One-click "Test all", search testing playground, per-indexer stats (queries, grabs, failures).
- Credentials in Keychain only.

### 4.4 Torrent engine

- Full libtorrent feature set: DHT, PEX, LSD, uTP, magnet links, v1/v2 torrents, encryption, UPnP/NAT-PMP, IPv6, web seeds, super-seeding off.
- **Network safety:**
  - Bind to a specific interface (e.g. VPN interface) with **kill switch** (traffic stops if the interface disappears).
  - Built-in support for detecting common VPN clients' interfaces; WireGuard config in-app is a stretch goal.
  - Optional leak test and IP display in Settings.
- Queueing, scheduling (alt-speed windows, "pause while on battery / cellular hotspot / metered network"), global/per-torrent limits, ratio and seed-time goals (with per-tracker rules).
- Disk: preallocation modes, incomplete folder → completed folder, external drives and network shares supported with graceful reconnect, free-space guard (refuses to grab if insufficient space).
- Fast resume, checking, recheck, move-storage, force-announce, tracker status, peers/pieces visualization (a real piece map, not a number).
- Sleep handling: `IOPMAssertion` while actively downloading (configurable); wake-resume.
- **Activity view:** unified downloads + imports + searches + subtitle jobs timeline, with ETA that accounts for the full pipeline ("Ready to watch in ~2 min").

### 4.5 Streaming (the headline feature)

How it works: choosing Play on a title with no local file triggers search → auto-pick best *streamable* release → add torrent in **streaming mode** → player opens once buffer threshold is met.

- **Streamability scoring:** the release picker adds a streaming-specific score — seeders/health, container (MP4/MKV with indexes at head), bitrate vs. measured throughput, availability of first pieces, episode vs. season pack (for single-episode requests selects only the needed file; for season playback prefers a healthy complete pack, see below).
- **Piece scheduling:** libtorrent piece **deadlines** for a sliding window ahead of the playhead; head and tail (MKV cues / MP4 moov) prefetched first; seek → reprioritize immediately; remaining file continues sequentially behind the playhead so the full file always finishes.
- **Adaptive buffering:** measures sustained throughput and predicts whether playback will stall; starts when `P(no stall for remaining runtime) ≥ threshold`, or "starting soon" with an honest ETA otherwise. Displays a minimal, truthful state ("Finding peers… Buffering 12 s ahead").
- **Pre-warming:** hovering/long-focus on Play, "Up next" episode pre-fetches the next episode's first segment in the background (configurable, bandwidth-capped).
- **Quality fallback:** if the chosen release can't keep up, offer one-tap "Try a smaller version" that swaps release without losing position.
- **Seamless download conversion:** a stream is just a download that's being watched. When it finishes, it's imported into the library via the normal importer; if the user is still watching, the player switches to the local file with no hiccup.
- **"Stream only" mode:** option to not keep the file (cache with a size cap + auto-evict, resume-safe), or "Keep" toggle in the player.
- **Season packs & multi-episode archives (first-class):**
  - **Pack-aware picking:** when the user plays a season (or "Play from the beginning"), the picker prefers a complete-season torrent over single episodes when it is healthy, since it gives one swarm, consistent quality and release group, and no per-episode searching. Complete-series packs are supported too (file-to-season mapping).
  - **File mapping:** every file in the torrent is parsed and mapped to episodes (handles S01E01, 1x01, absolute numbers, date-based, multi-episode files like E01-E02, specials/S00, extras and samples excluded). The mapping is shown in a review table the user can correct, and corrections are remembered.
  - **Ordered streaming plan:** the stream starts at **episode 1** (or the first unwatched episode, or the one the user chose) with priority on that file; remaining files get a descending priority gradient in episode order, so episode 2's head/tail is already arriving while episode 1 plays. Deadlines slide across file boundaries, so autoplay into the next episode has no buffering gap.
  - **Everything still downloads:** non-selected episodes download in watch order behind the playhead; users can also pick "download whole season", "only episodes I choose", or "stream only, don't keep".
  - **Per-episode import:** episodes are imported and renamed as soon as each file completes and verifies (no waiting for the whole pack), while the torrent keeps seeding from the original location via clone/hardlink. Partially downloaded packs show per-episode progress rings in the season list.
  - **Mixed sources:** if a pack is missing an episode (or one is bad/hash-failed), only that episode falls back to a single-episode search and the player stitches it in seamlessly.
  - **Archives inside torrents (RAR/ZIP/7z multi-volume):**
    - *Stored (uncompressed) volumes* are streamed directly: the app reads the archive headers, maps the inner file's byte ranges across volumes to torrent pieces, and plays it with no extraction, using the same range server.
    - *Compressed archives* can't be seeked until unpacked, so they use a **streaming extractor**: volumes are fetched in order and unpacked incrementally to a temp file while playing; seeking is limited to the unpacked range, with an honest indicator, and the UI says why.
    - Encrypted/password archives prompt once and are never auto-trusted. Extraction runs sandboxed with size/ratio limits (zip-bomb protection); extracted files are verified, imported, and the temp copy is cleaned up per the user's seeding preference.
  - **Binge UX:** "Play season" / "Play from episode 1" on the season row, an episode strip in the player showing buffered-ahead state per upcoming episode, Up Next autoplay with intro/credits skipping, and resume at the exact episode/time on any device.
- **Failure UX:** dead torrent, stalled, wrong content, hash failure → automatic retry with the next-best release, blocklisting the bad one, and a plain-language message — never a raw error.

### 4.6 Player

- Fullscreen-first, borderless immersive window; Liquid Glass transport controls that fade in/out; trackpad gestures (scrub, two-finger swipe for seek, pinch for aspect fill), full keyboard and media-key control, Touch-free Magic Remote–like Siri Remote support via Bluetooth/HID.
- **Format support:** everything common — H.264/HEVC/AV1/VP9, 8/10-bit, HDR10/HDR10+/HLG/Dolby Vision (best effort: DV Profile 5/8 via AVPlayer when possible, tone-mapping otherwise), DTS/DTS-HD/TrueHD/Atmos (passthrough over HDMI/eARC where hardware allows; downmix otherwise), FLAC/Opus/AAC/AC3/EAC3.
- **Subtitles:** SRT/ASS/SSA/PGS/VobSub/WebVTT; embedded, external and auto-downloaded; style overrides, position/offset/sync adjustment with live nudge (`[` `]`), per-language preferences, forced-subs auto selection, SDH preference, dual subtitles (language learning).
- **Audio:** track picker with codec/channel info, night mode (dynamic range compression), loudness normalization, per-device output switching, audio delay.
- **Features:** chapters with thumbnails, scrub preview thumbnails (generated progressively), skip intro/credits (chapter markers + audio-fingerprint detection, local), auto "Up next" with countdown, resume where left off across devices (iCloud), speed control with pitch correction, A–B loop, screenshots, Picture-in-Picture, AirPlay 2 (via AVPlayer path), Apple TV hand-off, Now Playing / media keys / Control Center integration, Do Not Disturb/Focus-aware.
- **Stats overlay** (`I`): bitrate, dropped frames, buffer, peers, piece map, decode path (hardware/software), color pipeline.
- Hardware decode via VideoToolbox everywhere possible; Metal-based renderer with proper EDR output on HDR displays; display refresh/frame-rate matching.
- **Watch state:** auto-mark watched at credits/90%, manual toggle, Trakt scrobble (opt-in), rating.

### 4.7 Subtitles (Bazarr, integrated)

- Per-language profiles (required, optional, hearing-impaired policy, forced), providers (OpenSubtitles.com, Subdl, Podnapisi, Addic7ed-style via user-supplied accounts where needed, etc.).
- Automatic search on import and on upgrade; **score by hash match** (OpenSubtitles hash computed from streamed pieces), release-group and framerate match.
- Auto-sync (audio-based alignment) and manual offset; embedded subtitle extraction to sidecar; conversion (SRT/ASS/WebVTT).
- Subtitles available **during streaming** before the download is complete (fetch by hash of first/last 64KB).

### 4.8 Music (v1.5, Lidarr-class)

Artists/albums via MusicBrainz, release matching with quality profiles (FLAC/MP3 320), tagging via embedded tag editor, library view with album art grid, integrated gapless player, and the same stream-while-downloading pipeline. Scoped separately after v1 ships.

### 4.9 Integrations

- **Media servers:** Plex, Jellyfin, Emby library refresh and play-state sync (optional — Marquee is a full player by itself).
- **Trakt:** collection, watchlist, scrobble, lists.
- **Notifications:** native macOS notifications with actions ("Watch now"), plus optional Discord/Telegram/Pushover/ntfy/webhook.
- **Shortcuts & App Intents:** "Play next episode of X", "Add movie", "What's downloading?". Spotlight indexing of library titles. Siri phrases. Widgets (Up Next, Downloading, Calendar). Menu bar extra (speeds, active streams, pause all).
- **URL scheme & handlers:** registers for `magnet:` and `.torrent` files (with explicit user opt-in), `marquee://` deep links.
- **Public API:** local REST/WebSocket API (disabled by default, token auth) and Sonarr/Radarr-compatible API subset so existing third-party tools keep working.

---

## 5. UX bar (the "extremely high" part)

### 5.1 Information architecture

Sidebar (collapsible, `⌘⌥S`): **Home · Discover · Library (Movies / TV / Music) · Calendar · Activity · Search** + smart collections; Settings in standard `⌘,`.

- **Home:** "Continue watching", "Next up", "New for you" (newly imported), "Downloading now" (live progress ring on poster), "Recommended", "Coming soon".
- Poster-centric grid with dynamic sizing slider, 120 fps scroll, progressive image loading with blur-hash/placeholder, adaptive color theming from artwork on detail pages.
- **Detail pages:** full-bleed backdrop, parallax, glass overlay; primary actions: **Play** / **Resume** / **Download** / **Monitor**. Season/episode list with watched states, per-episode quality badges, file info on hover.

### 5.2 Interaction quality

- **Keyboard-first:** every action reachable by shortcut; `⌘K` command palette; full-keyboard navigation of grids (arrows, Space for Quick Look-style preview, Return to play); shortcut cheat-sheet (`?`).
- **Drag & drop:** drop magnet links, `.torrent` files, folders to import, posters to share.
- **Undo everywhere** (`⌘Z`): delete, unmonitor, rename batch, profile changes.
- **Optimistic UI** for all local state changes; no modal blocking for background work.
- **Motion:** purposeful spring animations, shared-element transitions from poster → detail → player, respecting Reduce Motion.
- **Loading states:** skeletons rather than spinners; all lists work offline with cached data; clear offline/degraded banners.
- **Empty states** that teach and offer the next action; **error messages** in plain language with a fix button, never stack traces (technical details one click deeper, copyable).
- **Progressive disclosure:** "Simple" vs. "Advanced" toggle per settings page; wizards for quality profiles and custom formats with live "would this release match?" testing.
- **Trust & transparency:** every automated decision has a "why", every destructive action previews its effect (files affected, space freed) and is reversible via Trash.

### 5.3 First-run experience (target: < 5 minutes to first playback)

1. Welcome + choose **Standalone** or **Connect to existing arr stack**.
2. Pick library folder(s) / download folder (with disk-space preview; external drives supported).
3. Add an indexer (curated picker + paste Torznab URL) or import from Prowlarr/Jackett.
4. Choose a quality preset (visual comparison: size per hour, device compatibility).
5. Optional: VPN interface binding check; Trakt login; subtitle languages.
6. Import existing library or search for something and press Play. Live checklist shows "Engine ready ✓ Indexers ✓ Library ✓".

### 5.4 Visual design

- Liquid Glass materials per macOS 26 HIG, SF Pro + SF Symbols, native controls first, custom only where the product demands (player, posters).
- Light, Dark and Auto; tinted accent from artwork; high-contrast variant; HDR-aware UI elements near video.
- A design system package (`MarqueeUI`) with tokens (spacing, type, radii, motion), reusable components, and a living gallery app for design review.

### 5.5 Accessibility & localization

- Full VoiceOver (custom rotor for episodes/seasons), Voice Control, Full Keyboard Access, Dynamic Type where applicable, Reduce Motion/Transparency, increased contrast, captions styled via system caption preferences.
- Localization from day one (String Catalogs): English v1, then ES/FR/DE/PT/JA/KO/ZH; RTL-ready layout; localized metadata via TMDB language preference.

### 5.6 Performance budgets

| Metric | Budget |
|---|---|
| Cold launch to interactive Home | < 1.0 s (library of 10k items) |
| Warm launch | < 400 ms |
| Scroll | 120 fps on ProMotion, no dropped frames in grids of 5k+ posters |
| Library search | < 50 ms keystroke-to-results |
| Press Play (cached release, healthy swarm) → first frame | < 8 s median, < 20 s p95 |
| Seek (within downloaded range) | < 150 ms; (outside) < 3 s with indicator |
| App download size | < 60 MB universal (< 35 MB per-arch), LGPL libs stripped to what is used |
| Idle memory | < 150 MB UI + < 100 MB helper (UI releases image/decoded caches when backgrounded) |
| Active streaming memory | < 400 MB total including player |
| Idle CPU | ~0% (no timers or polling; event-driven, coalesced wakeups) |
| Playback CPU (1080p HEVC, Intel) | Hardware decode via VideoToolbox; < 15% of one core for app overhead |
| Battery | Helper uses coalesced timers; no wakeups when idle |

---

## 6. Data model (core entities)

`Title` (movie|series|artist) → `Season` → `Episode` → `MediaFile` · `Release` (parsed, scored) · `Grab` (decision log) · `Torrent` (engine state mirror) · `StreamSession` · `Indexer` · `QualityProfile` · `CustomFormat` · `DelayProfile` · `RootFolder` · `SubtitleTrack` · `SubtitleProfile` · `WatchState` · `HistoryEvent` · `BlocklistEntry` · `Notification` · `HealthIssue` · `Tag`.

Principles: normalized, event-sourced history (for "why" explanations and undo), UUID primary keys, soft deletes, migrations tested against fixture databases from every released version.

---

## 7. Key technical challenges & mitigations

| Challenge | Mitigation |
|---|---|
| Reliable playback of MKV/HEVC/DTS/PGS on Mac | libmpv path as default; AVPlayer fast path only when it adds value; extensive format test corpus |
| Streaming a file that is still downloading | Local range server + piece deadlines; synthetic stalling swarm in tests; head/tail prefetch for index data |
| Season packs & archives (messy file naming, multi-volume RAR) | Per-file episode mapping with user-correctable review, ordered priority gradient across files, direct streaming of stored archives, incremental extractor for compressed ones, corpus of real pack layouts in tests |
| Release-name parsing accuracy | Port/inspire from proven open-source parsers (Sonarr/Radarr parser test corpora are public), property-based tests, 10k+ real-world name fixture set, continuous regression suite |
| Metadata mismatches (scene vs. TVDB numbering, anime) | Scene mapping databases, absolute order support, manual override UI |
| Indexer breakage (Cardigann definitions change) | Auto-updating definitions with signed manifest, canary tests, graceful per-indexer degradation |
| Download engine crash or UI crash | Helper daemon isolated via XPC; auto-restart; fast-resume state flushed frequently |
| External/network volumes disconnecting | Volume watcher, pause-and-resume, no destructive action on missing paths |
| Privacy leaks | Interface binding + kill switch tested against leak scenarios; DNS/peer announce only through bound interface |
| Hardlink/clone across volumes | Detect capabilities, fall back to copy with explicit UI; never silently double disk usage |
| Large libraries (50k+ files) | Indexed queries, lazy loading, incremental scans via FSEvents, background import queues |
| Maintaining parity with the arr suites | Define "parity checklist" per app (§9) and track as acceptance tests |

---

## 8. Security & privacy

- Hardened runtime, notarization, signed helper, XPC with code-signing-requirement validation.
- Secrets (API keys, tracker passkeys, provider logins) in Keychain only.
- Local API & stream server: loopback only, random tokens, Host/Origin checks (anti DNS-rebinding), disabled by default for non-stream APIs.
- Archive extraction and media probing run in restricted subprocesses with timeouts; never execute downloaded files; quarantine flags applied; warn on executable/suspicious releases (.exe, .scr, fake-video with archive payload).
- No telemetry by default. Opt-in crash reports (anonymized) via a self-hosted or privacy-respecting service. Update checks via signed Sparkle feed.
- All metadata API calls go through the app (no user-identifying IDs); optional proxy setting for metadata/indexer calls.

---

## 9. Feature parity checklist (acceptance baseline)

**Sonarr:** series add/monitor, season pass, episode search, RSS, quality profiles, custom formats, delay profiles, release profiles, naming, import lists, scene mapping, calendar, wanted/missing/cutoff, history/blocklist, rename/organize, tags, notifications, health, backup/restore, API compatibility subset.
**Radarr:** all of the above for movies + collections, minimum availability, import lists (Trakt/TMDB lists), movie search, extra files.
**Prowlarr:** indexer add/test/sync, categories, stats, search, app sync (for Connect mode), proxies.
**Bazarr:** language profiles, providers, auto search, sync, manual search, history.
**Overseerr (single-user):** discover, watchlist, request→add, availability status.
**qBittorrent-class:** queue, limits, scheduling, categories, tags, trackers, peers, IP filtering, RSS-less.

Each item becomes an acceptance test or manual QA checklist entry.

---

## 10. Delivery plan

Solo/small team assumption (1–3 engineers + design). Estimates are calendar time at that size.

| Phase | Duration | Deliverable | Exit criteria |
|---|---|---|---|
| **0. Spikes** | 3–4 wks | (a) libtorrent XPC helper + range server streaming a file that is still downloading into libmpv; (b) release parser prototype vs. fixture corpus; (c) Metal player rendering HDR; (d) design language prototype | Stream starts < 15 s on a healthy swarm; seek works; parser ≥ 98% on fixtures; go/no-go on architecture. Also prove: a season-pack torrent plays ep 1 then rolls into ep 2 with no gap, and a stored multi-volume RAR streams without extraction |
| **1. Foundations** | 6–8 wks | Core package, DB, helper daemon, settings, onboarding skeleton, design system, Cardigann/Torznab client, TMDB/TVDB metadata, library add flow | Add a title, search indexers, see results with scoring, grab, and download to a folder |
| **2. Core loop (Alpha)** | 8–10 wks | Monitoring, RSS, quality profiles, importer/renamer, activity view, calendar, history/blocklist, player v1 (libmpv), streaming v1, health center | Daily-drivable for author; movies + TV flow end-to-end including Play-while-downloading |
| **3. Polish & depth (Beta)** | 8–10 wks | Custom formats UI, delay profiles, subtitles, Discover, command palette, widgets/Shortcuts/Spotlight, VPN kill switch, migration importers, Connect mode, AVPlayer/AirPlay/PiP path, accessibility pass, localization infra | Private beta with 25–100 users; crash-free sessions > 99.5% |
| **4. Hardening (RC)** | 4–6 wks | Perf budgets met, security review, update channel, backup/restore, docs/site, telemetry-free diagnostics bundle, Dolby Vision/Atmos polish | All budgets green; parity checklist ≥ 95%; no P0/P1 |
| **v1.0 release** | | Public launch | |
| **v1.5** | +8–10 wks | Music (Lidarr-class), Trakt scrobble polish, WireGuard in-app (stretch) | |
| **v2** | | iPhone/iPad/Apple TV companions, headless server mode + web UI, Usenet, multi-user requests | |

**Total to v1.0: ~7–9 months** for a small team; longer for solo part-time. The streaming and player work is the critical path; spike it first.

### Suggested first sprint

1. Create Xcode workspace: `Marquee.app`, `MarqueeHelper`, `MarqueeCore`, `MarqueeUI` packages.
2. Build libtorrent as an XCFramework; expose a minimal Swift API (add magnet, file list, set priorities/deadlines, read range).
3. Loopback range server + libmpv playing from it.
4. Release parser + fixture corpus harness.
5. Design exploration: Home, title detail, player controls, activity (Figma or prototyped in SwiftUI).

---

## 11. Quality & testing strategy

- **Unit:** parser, scoring, naming templates, quality profile engine, custom format matching (property-based + golden files).
- **Integration:** in-process fake indexers (Torznab fixtures), local tracker + seeder containers for deterministic swarms, simulated throttling/drops/disconnects, filesystem fault injection (disk full, volume removal).
- **E2E:** scripted flows (add → search → grab → stream → import → upgrade) in CI against fixture swarm.
- **Player matrix:** 200+ sample files (containers × codecs × HDR × audio × subtitles) with automated first-frame/AV-sync checks.
- **UI:** snapshot tests for components/states, XCUITest for critical flows, accessibility audits, performance tests (`XCTMetric`) for budgets in §5.6.
- **Soak:** 72-hour download/seed run with memory/FD leak detection.
- **Beta:** TestFlight-style channel via Sparkle beta feed; in-app "Send diagnostics" bundle (logs scrubbed of secrets/paths on request).

---

## 12. Success metrics

- Time-to-first-playback from fresh install ≤ 5 min (median, in usability tests).
- Press-Play-to-first-frame medians per §5.6.
- ≥ 95% of grabs imported with correct naming without user intervention.
- Crash-free sessions ≥ 99.7%; helper uptime ≥ 99.9%.
- SUS usability score ≥ 85 in moderated sessions with both arr power-users and non-technical users.
- No data-loss incidents (files deleted/overwritten unintentionally) — zero tolerance.

---

## 13. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| libmpv/Metal HDR + Dolby Vision gaps | Medium | AVPlayer path for DV; tone-mapping fallback; scope DV as best-effort |
| Streaming quality depends on swarm health | High (UX) | Honest buffering UX, fallback release, pre-warm, streamability scoring |
| Scope creep from "everything in the arr suite" | High | Phase gates, parity checklist is the cap, music/usenet/server deferred |
| Indexer/definition maintenance burden | Medium | Pluggable definition source, community-maintained, auto-update, graceful degradation |
| Upstream API/ToS changes (TMDB, TVDB, subtitle providers) | Medium | Abstraction layers, user-supplied API keys option, caching |
| Legal/platform exposure (see §14) | Medium | Content-agnostic design, no bundled sources, clear ToS, direct distribution |
| Solo bus-factor / maintenance | Medium | Modular packages, strong tests, docs |

---

## 14. Legal & ethical notes

The \*arr suite, libtorrent, mpv and VLC are lawful tools; legality depends on what content a user accesses. To keep this project on solid ground:

- Ship **no indexers, trackers, or content links**; users add their own sources.
- Surface legal availability (TMDB watch providers) in the UI, and make it easy to use legally obtained content (own rips, public domain, Creative Commons, open torrents like Blender/Internet Archive) for demos and screenshots.
- Use only licensed/permitted metadata and image sources, with required attribution.
- Provide a clear user-responsibility statement at first run, and keep copyright-complaint contact details if ever distributed publicly.
- Consider counsel review before public release, particularly for distribution outside personal use.

---

## 15. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| 1 | Standalone engine vs. wrapper around existing arr instances | Both: Standalone by default, Connect mode for existing users (§4.1) |
| 2 | Player: libmpv vs. VLCKit vs. AVPlayer-only | libmpv primary + AVPlayer fast path; AVPlayer-only can't handle MKV/PGS/DTS well |
| 3 | Mac App Store vs. direct | Direct (Developer ID + Sparkle) |
| 4 | Distribution scope: personal tool vs. public release | **Decided: public release.** Hardening, accessibility, onboarding, notarization and legal review are in scope |
| 5 | Usenet in v1? | No; the architecture's `Downloader` protocol leaves room |
| 6 | Open source? | **Decided: closed source.** Source repo is private-by-intent; mpv/ffmpeg must be LGPL builds, dynamically linked and replaceable, with attribution and relinking notices; libtorrent is BSD |
| 7 | Minimum macOS | **Decided: Intel Macs are supported.** Universal binary (arm64 + x86_64); every native dependency (libtorrent, libmpv, ffmpeg) must be built for both. Intel perf budgets are tracked separately (software-decode fallbacks, no assumption of Apple Silicon media engines). Minimum macOS 15 |
| 8 | Project name & identity | TBD (Marquee is a placeholder) |
