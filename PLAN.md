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
- ◐ Quality engine: profiles, custom formats, scoring, streamability score, "why this release" — `Quality`
- ◐ libmpv LGPL universal build + Metal player view (`PlaybackEngine` protocol)
- ☑ Torrent engine ↔ stream server bridge (piece deadlines follow playhead) — `MarqueeEngine`
- ☐ Helper daemon (`SMAppService` login item) + XPC

## Wave 3 — Phase 1 exit: add → search → grab → stream
- ☐ Wire UI to real services (library, discover, search, activity)
- ☐ Importer/renamer (APFS clone/hardlink, templates), monitoring + RSS
- ☐ First-run onboarding, settings
- ☐ End-to-end flow test against fixture swarm + fake indexer

## Follow-ups from reviews
- Metadata: public memberwise inits on domain models (needed for UI mocks/wiring); disk cache size cap + eviction; popular/upcoming/person/collection endpoints.
- Indexers: fall back to text search when an id search returns nothing; persist auto-disable state; Cardigann YAML definitions (SCOPE §4.3); Keychain store integration test.
- Streaming: `GrowingFileByteSource` should return the contiguous available prefix instead of waiting for a whole 256 KiB chunk (faster first byte); hash-failed piece handling; idle-connection timeout; serve `[::1]`.
- Persistence: repositories for indexers/profiles/custom formats/root folders/blocklist/health/subtitles/release+grab; monitor-mode episode selection; SubtitleProfile + Notification tables; title runtime/genres; pack corrections keyed by infoHash only; observe() swallows query errors.
- Parser: corpus is author-written (100% overstates real-world accuracy) — grow it from real indexer results; title-ending years without a release year (Wonder.Woman.1984), DD/MM date ambiguity, bare group tags, `DDP5 1` channels, bare 3–4 digit episodes without a trailing quality tag.
- UI: `-initialDetail` launch hook doesn't sync sidebar selection; Discover/Calendar placeholders; settings don't persist; no UI-model tests (FuzzyIndex, Formatters); macOS 15 fallback unverified.
- TorrentEngine: measure idle CPU with libtorrent's internal tick (`tick_interval`) against §5.6 and pause/sleep the session when idle; libtorrent tarball SHA is trust-on-first-use.
- Packs: corpus is author-written; DD/MM ambiguity, bare 3–4 digit episodes, absolute numbers without folder hint; opaque whole-pack archives disable gap detection; inner-archive byte ranges (stored RAR streaming) not yet implemented.
- Engine (priority): time-to-first-byte is ~5–6 s on loopback because libtorrent issues deadline requests on its tick; implement a progressive deadline window (head + small window first, extend as pieces land) and consider a shorter tick while streaming. Investigate the one unreproduced seek read that returned mismatched bytes (data integrity). Archive episodes throw `archiveStreamingUnsupported`; `fileCompleted` not emitted for already-complete files at add; re-adding an existing hash unhandled.
