# AGENTS.md

Living instructions for any AI agent working in this repo. **Keep this file current:** whenever the user gives a durable instruction, preference, decision or feedback (positive or negative), add or revise an entry below in the same turn (a hook in `.claude/` reminds agents on every prompt). Date entries `YYYY-MM-DD`, replace superseded ones rather than stacking, keep it terse. Full product spec: [SCOPE.md](SCOPE.md). Execution tracker: [PLAN.md](PLAN.md) (update status when work merges).

## Project
Marquee (working title): native macOS app combining the *arr suite with a built-in torrent engine and streaming player. Repo: git@github.com:danskullz/tv.git

## Decisions & constraints
- 2026-10-09 Public release, **closed source**. Use LGPL builds of mpv/ffmpeg, dynamically linked; libtorrent is BSD.
- 2026-10-09 **Intel Macs must be supported**: universal binary (arm64 + x86_64), every native dependency built for both. Minimum macOS 15.
- 2026-10-09 **As lightweight and performant as possible**: native Swift only (no Electron/WebView), minimal dependencies, tiny idle cost, budgets in SCOPE.md §5.6 are release gates.
- 2026-10-09 Must handle full season packs and archives; streaming starts at episode 1 (see SCOPE.md §4.5).
- 2026-10-09 Ships no indexers or content links (content-agnostic).
- 2026-10-09 OpenSSL stays in the torrent engine (~5 MB/arch) for HTTPS trackers/web seeds; user approved the size cost.

## Build, CI & release
- SwiftPM package: `MarqueeCore` (UI-free logic, depends on GRDB), `MarqueeUI` (design system + views), `Marquee` (app), tests in `Tests/`.
- 2026-10-09 Xcode 26.5 is installed but not `xcode-select`ed; run tests locally with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (do not change xcode-select). Dev machine is an Intel i7 (x86_64), 8 cores.
- 2026-10-09 GitHub Actions (`.github/workflows/release.yml`, `macos-26` runners with the newest Xcode 26 selected — the UI needs the macOS 26 SDK) on every push to `main`: test, build arm64 + x86_64, lipo a universal binary, bundle `.app` (`scripts/bundle.sh`), zip all three, publish a new GitHub Release `v0.1.<run_number>`.
- 2026-10-09 Native deps: run `scripts/build-libtorrent.sh` once (universal static libtorrent 2.0.15 + OpenSSL 3.5 for TLS + trimmed Boost headers into git-ignored `Vendor/libtorrent`, cached in `~/Library/Caches/Marquee/deps`, idempotent). Run it in every fresh checkout/worktree before `swift build`/`swift test` (instant when the cache is warm; the whole package depends on it). The torrent engine is a C shim (`CTorrentShim`, pure-C header) wrapped by `actor TorrentSession`; BitTorrent protocol encryption uses libtorrent's own RC4/DH, OpenSSL is only for HTTPS trackers/web seeds.
- Signing/notarization (Developer ID) is not wired up yet; builds are ad-hoc signed.
- 2026-10-09 Playback libs: `scripts/build-mpv.sh` builds LGPL universal libmpv + FFmpeg dylibs (pinned, SHA-256-verified) into `Vendor/mpv/` (git-ignored; build cache in `.deps-cache/`). `MarqueePlayer` `dlopen`s libmpv at run time (from `Contents/Frameworks`, or `Vendor/mpv/lib` in dev, or `$MARQUEE_LIBMPV`), so `swift build` works without it and the player tests skip when it is absent; CI builds it first (cached on the script hash). mpv must stay `-Dgpl=false` and FFmpeg without `--enable-gpl/--enable-version3/--enable-nonfree`; see [docs/licenses.md](docs/licenses.md). Rendering is OpenGL (`CAOpenGLLayer` + libmpv render API); a Metal/EDR path is future work.

- 2026-10-09 Demo/test content: `-demoSwarm YES` launches the app on a private demo library (separate DB, in-memory secrets) with a loopback fake Torznab indexer + seeder serving a generated test-pattern series ("Marquee Test Pattern") and movie; `-mockData YES` shows `MockLibrary`. CI runners have no video encoder: automated tests must never encode (use `Tests/MarqueePlayerTests/Fixtures/test-clip.mp4`); the app falls back to the bundled `demo-clip.mp4`.

## Code conventions
- Swift 6 language mode, strict concurrency: value types are `Sendable`, services are `actor`s, UI state is `@Observable` on `@MainActor`.
- `MarqueeCore` is organized by area folder: `Parsing/`, `Indexers/`, `Metadata/`, `Persistence/`, `Streaming/`, `Quality/`, `Packs/` (add new ones as needed). Tests mirror it under `Tests/MarqueeCoreTests/<Area>/`; fixtures under `Tests/MarqueeCoreTests/Fixtures/<Area>/`, loaded via `Bundle.module`. Test helpers/mocks are `private` (all tests share one module); helpers shared across files carry an area prefix, e.g. `makeIndexerRelease`.
- Tests use Swift Testing (`import Testing`), never hit the live network, and must pass before work is merged. CI VMs have no video encoder: tests must not encode media at runtime — commit small generated fixtures instead (e.g. `Tests/MarqueePlayerTests/Fixtures/test-clip.mp4`).
- No new dependencies without orchestrator approval; prefer Foundation/Network/system frameworks. Approved: GRDB.
- Brief doc comments on public API; no comments narrating the obvious.

## Working style / feedback
- 2026-10-09 Screenshots: capture ONLY the Marquee window (`screencapture -x -o -l <windowID>`), never the full screen — the user's other windows are private. Delete any accidental full-screen capture unviewed.
- 2026-10-09 UI bar is very high and the user checks it closely: every UI change must be verified by running the app and inspecting window screenshots (light + dark, scrolled states) before merge. Use stock macOS 26 chrome (sidebar, toolbar, scroll-edge effects); no toolbar-background hacks or heavy opaque panels over artwork.
- 2026-10-09 Build mode: the main session acts as orchestrator, delegating to Sonnet 5.5 / Haiku 5.5 subagents at no more than `high` effort, and owns review, integration and quality.
- 2026-10-09 User wants a complete scope first, then build; prefers decisions made with a recommendation rather than long option lists.
