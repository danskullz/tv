# Build plan

Execution tracker for [SCOPE.md](SCOPE.md) §10. Each item is a workstream owned by one agent in its own worktree, reviewed and merged by the orchestrator. Status: ☐ todo · ◐ in progress · ☑ merged.

## Wave 1 — Phase 0 spikes + independent foundations
- ◐ Release-name parser + ≥400-name fixture corpus (≥98% accuracy gate) — `MarqueeCore/Parsing`
- ◐ Torznab client, Keychain secret store, parallel search coordinator — `MarqueeCore/Indexers`
- ◐ TMDB client with caching — `MarqueeCore/Metadata`
- ◐ Loopback HTTP range server + piece-aware byte sources — `MarqueeCore/Streaming`
- ◐ GRDB schema v1, FTS5 library search, repositories — `MarqueeCore/Persistence`
- ◐ libtorrent universal build + Swift engine wrapper + loopback swarm test + CI — `TorrentEngine`
- ◐ Design system + app shell on mock data — `MarqueeUI`, `Marquee`

## Wave 2 — streaming critical path
- ☐ Season-pack file→episode mapper + ordered streaming plan (priority gradient, cross-file deadlines) — `Packs`
- ☐ Quality engine: profiles, custom formats, scoring, streamability score, "why this release" — `Quality`
- ☐ libmpv LGPL universal build + Metal player view (`PlaybackEngine` protocol)
- ☐ Torrent engine ↔ stream server bridge (piece deadlines follow playhead)
- ☐ Helper daemon (`SMAppService` login item) + XPC

## Wave 3 — Phase 1 exit: add → search → grab → stream
- ☐ Wire UI to real services (library, discover, search, activity)
- ☐ Importer/renamer (APFS clone/hardlink, templates), monitoring + RSS
- ☐ First-run onboarding, settings
- ☐ End-to-end flow test against fixture swarm + fake indexer
