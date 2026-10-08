# AGENTS.md

Living instructions for any AI agent working in this repo. **Keep this file current:** whenever the user gives a durable instruction, preference, decision or feedback (positive or negative), add or revise an entry below in the same turn (a hook in `.claude/` reminds agents on every prompt). Date entries `YYYY-MM-DD`, replace superseded ones rather than stacking, keep it terse. Full product spec: [SCOPE.md](SCOPE.md).

## Project
Marquee (working title): native macOS app combining the *arr suite with a built-in torrent engine and streaming player. Repo: git@github.com:danskullz/tv.git

## Decisions & constraints
- 2026-10-09 Public release, **closed source**. Use LGPL builds of mpv/ffmpeg, dynamically linked; libtorrent is BSD.
- 2026-10-09 **Intel Macs must be supported**: universal binary (arm64 + x86_64), every native dependency built for both. Minimum macOS 15.
- 2026-10-09 **As lightweight and performant as possible**: native Swift only (no Electron/WebView), minimal dependencies, tiny idle cost, budgets in SCOPE.md §5.6 are release gates.
- 2026-10-09 Must handle full season packs and archives; streaming starts at episode 1 (see SCOPE.md §4.5).
- 2026-10-09 Ships no indexers or content links (content-agnostic).

## Build, CI & release
- SwiftPM package: `MarqueeCore` (UI-free logic), `Marquee` (app), tests in `Tests/`. Local machine has only Command Line Tools, so `swift test` cannot run locally (no Testing/XCTest); `swift build` works. Tests run in CI.
- 2026-10-09 GitHub Actions (`.github/workflows/release.yml`) on every push to `main`: test, build arm64 + x86_64, lipo a universal binary, bundle `.app` (`scripts/bundle.sh`), zip all three, publish a new GitHub Release `v0.1.<run_number>`.
- Signing/notarization (Developer ID) is not wired up yet; builds are ad-hoc signed.

## Working style / feedback
- 2026-10-09 User wants a complete scope first, then build; prefers decisions made with a recommendation rather than long option lists.
