# Build plan

Execution tracker for [SCOPE.md](SCOPE.md) §10. Each item is a workstream owned by one agent in its own worktree, reviewed and merged by the orchestrator. Status: ☐ todo · ◐ in progress · ☑ merged.

## Wave 1 — Phase 0 spikes + independent foundations
- ☑ Release-name parser + ≥400-name fixture corpus (≥98% accuracy gate) — `MarqueeCore/Parsing`
- ☑ Torznab client, Keychain secret store, parallel search coordinator — `MarqueeCore/Indexers`
- ☑ TMDB client with caching — `MarqueeCore/Metadata`
- ☑ Loopback HTTP range server + piece-aware byte sources — `MarqueeCore/Streaming`
- ☑ GRDB schema v1, FTS5 library search, repositories — `MarqueeCore/Persistence`
- ☑ libtorrent universal build + Swift engine wrapper + loopback swarm test + CI — `TorrentEngine`
- ☑ Design system + app shell on mock data — `MarqueeUI`, `Marquee`

## Wave 2 — streaming critical path
- ☑ Season-pack file→episode mapper + ordered streaming plan (priority gradient, cross-file deadlines) — `Packs`
- ☑ Quality engine: profiles, custom formats, scoring, streamability score, "why this release" — `Quality`
- ☑ libmpv LGPL universal build + player view (`PlaybackEngine` protocol; OpenGL render API for now)
- ☑ Torrent engine ↔ stream server bridge (piece deadlines follow playhead) — `MarqueeEngine`
- ☐ Helper daemon (`SMAppService` login item) + XPC

## Wave 3 — Phase 1 exit: add → search → grab → stream
- ☑ Play pipeline (search → decide → stream with auto-fallback) + AppServices + real LibraryDataSource + settings + loopback demo swarm (`-demoSwarm YES`)
- ◐ Player window: glass transport, buffering pre-roll, tracks, keyboard, media keys, up-next
- ☐ Wire remaining UI to real services (discover, calendar, activity)
- ☐ Importer/renamer (APFS clone/hardlink, templates), monitoring + RSS
- ◐ First-run onboarding links to real settings panes; guided checklist still static
- ☑ End-to-end flow test against fixture swarm + fake indexer (`DemoSwarmPipelineTests`)

## Follow-ups from reviews
- Metadata: public memberwise inits on domain models (needed for UI mocks/wiring); disk cache size cap + eviction; popular/upcoming/person/collection endpoints.
- Indexers: fall back to text search when an id search returns nothing; persist auto-disable state; Cardigann YAML definitions (SCOPE §4.3); Keychain store integration test.
- Streaming: `GrowingFileByteSource` should return the contiguous available prefix instead of waiting for a whole 256 KiB chunk (faster first byte); hash-failed piece handling; idle-connection timeout; serve `[::1]`.
- Persistence: repositories for indexers/profiles/custom formats/root folders/blocklist/health/subtitles/release+grab; monitor-mode episode selection; SubtitleProfile + Notification tables; title runtime/genres; pack corrections keyed by infoHash only; observe() swallows query errors.
- Parser: corpus is author-written (100% overstates real-world accuracy) — grow it from real indexer results; title-ending years without a release year (Wonder.Woman.1984), DD/MM date ambiguity, bare group tags, `DDP5 1` channels, bare 3–4 digit episodes without a trailing quality tag.
- UI: `-initialDetail` launch hook doesn't sync sidebar selection; Discover/Calendar placeholders; settings don't persist; no UI-model tests (FuzzyIndex, Formatters); macOS 15 fallback unverified.
- TorrentEngine: measure idle CPU with libtorrent's internal tick (`tick_interval`) against §5.6 and pause/sleep the session when idle; libtorrent tarball SHA is trust-on-first-use.
- Packs: corpus is author-written; DD/MM ambiguity, bare 3–4 digit episodes, absolute numbers without folder hint; opaque whole-pack archives disable gap detection; inner-archive byte ranges (stored RAR streaming) not yet implemented.
- Engine: archive episodes throw `archiveStreamingUnsupported`; streaming tuning is session-wide (ref-count for concurrent streams); `fileCompleted` not emitted for already-complete files at add; re-adding an existing hash unhandled; orderedDiskIO (single disk thread) untested on slow/network disks.
- Player: Metal/EDR path (libmpv render API is OpenGL-only; needs a libplacebo/Metal presenter fed by VideoToolbox IOSurfaces) — HDR is tone-mapped to SDR meanwhile; intermittent video-thread stall seen twice with terminal logging on (unexplained); arm64 slice built but never run; `mpv-configuration` embeds the build path.
- Release/legal (before public release): hardened-runtime library validation vs LGPL relinking (recommend documenting re-sign over disabling library validation); mirror the 8 LGPL source tarballs as release assets; EULA reverse-engineering clause; Acknowledgements screen (FreeType credit). See docs/licenses.md.
- Quality: persisting `QualityProfileConfig` flattens quality groups (needs a JSON column/repository — data loss otherwise); general-regex custom formats cost ~1.5–3 µs/candidate each (500 candidates ~5–7 ms) — add literal prefilters; stored vs compressed RAR needs torrent metadata; streamability weights need tuning against real swarms; parser doesn't flag `-Sample` suffix.
- Pipeline/app (vertical slice): no importer yet, so finished streams are not played from disk and library cards never reach `.local`; Discover/Calendar/Search-TMDB still placeholders; temporary `TemporaryPlayerPresenter` (Sources/Marquee/Services/PlayerPresenting.swift) to be swapped for `PlayerPresenter`; "Why this release?" UI not built (grab log has the data); measured-throughput and "try a smaller version" not wired; re-adding an existing torrent hash on replay is unguarded; Monitor/Download buttons on the detail page are still stubs; Torznab `.torrent` download URLs redirecting to magnets are not followed; library folders in Settings > Library are still placeholders.
