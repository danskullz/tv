import AppKit
import Foundation
import MarqueeCore

/// The public keys Marquee accepts update manifests signed with.
///
/// **This is the one value that has to match the private key in `MARQUEE_APPCAST_KEY_PEM`.**
/// Run `scripts/make-appcast.sh --print-keyring` after generating or rotating a key and paste the
/// result here. While this is empty the updater stays switched off rather than trusting anything —
/// an empty keyring cannot verify a signature, so there is no version of this that "works" without
/// a real key in it.
///
/// Keep the outgoing key alongside a new one for one release. Every install that has not updated
/// yet still verifies against the old key, and dropping it locks them out.
enum AppcastKeyringMarquee {
    // The live update channel's public key. Paste the output of
// `scripts/make-appcast.sh --print-keyring` after generating or rotating a key.
//
// Keep every key you have ever shipped, one release longer than you think you need to. An install
// that has not updated yet still verifies against the old key, and dropping it locks those users
// out permanently — they have no way to get a build containing the new one.
//
// The private half is the MARQUEE_APPCAST_KEY_PEM secret and exists nowhere in this repo. To
// rotate, see docs/updates.md: generate a new key, ship a build holding both, publish one release
// signed with the old one, then ship a build holding only the new.
static let keys: [String: Data] = [
    "marquee-2026": Data(base64Encoded: "N/IC69/HFc3axY+ki9WIpWI9tkbo2NVp/2UCIkane64=")!,
]

    static var keyring: AppcastKeyring {
        AppcastKeyring(keys.filter { !$0.value.isEmpty })
    }

    /// An empty keyring can never verify anything, so the updater refuses to start rather than
    /// reporting a signature failure the user can't act on.
    static var isConfigured: Bool { !keyring.keys.isEmpty }
}

/// What the updater is doing. Drives the sheet and the Settings row.
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateVersion)
        case downloading(Double)
        case preparing
        case installing
        /// Verified and on disk, but this copy of the app isn't in a place it may replace.
        case downloaded
        case failed(UpdateError)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .preparing, .installing: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle
    var isSheetShown = false
    /// The release being offered, kept separately from `State` so the sheet can render its notes
    /// without unpacking the enum on every redraw.
    private(set) var release: AppcastRelease?
    private(set) var lastCheckedAt: Date?

    /// `dev` when running unbundled (`swift run`, a worktree build), in which case there is no
    /// version to compare against and nothing to replace.
    let currentVersion: String
    let feedURL: URL

    private let checker: UpdateChecker?
    private let installer: UpdateInstaller
    private let stagingDirectory: URL
    private var staged: StagedUpdate?
    private var work: Task<Void, Never>?

    /// The app bundle this process is running from, and whether we may replace it.
    private(set) var installedBundle: URL = Bundle.main.bundleURL
    /// Only a copy in a real Applications folder can be swapped; a worktree build can't be.
    private(set) var canReplaceRunningApp: Bool = false

    init(feedURL: URL? = nil, currentVersion: String = AppInfo.version) {
        self.currentVersion = currentVersion
        // `-updateFeedURL=` points a debug build at a manifest that hasn't shipped yet. Plain http is
        // allowed there and nowhere else, so a real build can never be pointed at an open socket.
        let override = Self.overrideFeedURL()
        let resolvedFeed = override ?? feedURL ?? UpdateChecker.defaultFeedURL
        let bundle = Bundle.main.bundleURL
        let isDevelopment = currentVersion == "dev" || override != nil
        let root = Self.applicationSupportDirectory().appendingPathComponent("Updates", isDirectory: true)

        self.feedURL = resolvedFeed
        self.installedBundle = bundle
        self.canReplaceRunningApp = !isDevelopment && Self.isInApplications(bundle)
        self.stagingDirectory = root
        self.installer = UpdateInstaller(requirement: UpdateInstaller.requirementForRunningApp())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // No keyring means no signature can ever verify, and a "dev" build has no version to
        // compare and no bundle it is entitled to replace. Either way: off.
        guard AppcastKeyringMarquee.isConfigured, !isDevelopment else {
            self.checker = nil
            return
        }
        self.checker = UpdateChecker(
            currentVersion: UpdateVersion(currentVersion),
            feedURL: resolvedFeed,
            keyring: AppcastKeyringMarquee.keyring)
    }

    /// Release notes as attributed text, or nil when the release has none.
    var releaseNotes: AttributedString? {
        guard let notes = release?.notes, !notes.isEmpty else { return nil }
        return try? AttributedString(markdown: notes)
    }

    var downloadSizeDescription: String {
        guard let build = release?.build(for: BuildArch.host) else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(build.size), countStyle: .file)
    }

    // MARK: Checking

    /// The quiet, once-a-day check. Silent when there is nothing to say, and never run while the
    /// user is watching something: an update prompt that interrupts playback is the whole problem
    /// auto-update is supposed to avoid.
    func checkInBackgroundIfNeeded(isBusy: Bool) async {
        guard let checker, !isBusy else { return }
        do {
            guard await checker.isDue() else { return }
            let result = try await checker.check()
            lastCheckedAt = Date()
            guard case .available(let release) = result else { return }
            self.release = release
            state = .available(release.version)
        } catch {
            // A scheduled check that can't reach the network is not worth a dialog.
        }
    }

    /// "Check for Updates…" from the menu or Settings. Always goes to the network, and always tells
    /// the user what happened — including that nothing happened.
    func checkNow() async {
        guard let checker else {
            state = .failed(.notAnInstalledBuild(
                String(localized: "This copy of Marquee has no update key configured, so it can't update itself.")))
            isSheetShown = true
            return
        }
        state = .checking
        isSheetShown = true
        do {
            let result = try await checker.check(force: true)
            lastCheckedAt = Date()
            switch result {
            case .upToDate:
                release = nil
                state = .upToDate
            case .available(let release):
                self.release = release
                state = .available(release.version)
            }
        } catch let error as UpdateError {
            state = .failed(error)
        } catch {
            state = .failed(.network(error.localizedDescription))
        }
    }

    // MARK: Installing

    func install() async {
        guard let release, let build = release.build(for: BuildArch.host) else { return }
        guard !state.isBusy else { return }
        work?.cancel()
        work = Task { [self] in await runInstall(build: build, version: release.version) }
        await work?.value
    }

    private func runInstall(build: AppcastBuild, version: UpdateVersion) async {
        state = .downloading(0)
        do {
            let staged = try await installer.stage(build, version: version, scratchRoot: stagingDirectory) {
                [weak self] progress in
                let mapped: State = switch progress {
                case .downloading(let fraction): .downloading(fraction)
                case .verifying, .unpacking: .preparing
                case .checking: .preparing
                case .ready: .preparing
                }
                Task { @MainActor in self?.state = mapped }
            }
            guard !Task.isCancelled else {
                staged.cleanUp()
                return
            }
            self.staged = staged
            if canReplaceRunningApp {
                state = .installing
                try Self.replaceRunningApp(with: staged)
            } else {
                // A build running from somewhere it must not overwrite — a worktree, a copy on the
                // Desktop. Downloading it is still useful; replacing ourselves is not ours to do.
                state = .downloaded
                isSheetShown = true
            }
        } catch is CancellationError {
            state = .failed(.cancelled)
        } catch let error as UpdateError {
            state = .failed(error)
        } catch {
            state = .failed(.installFailed(error.localizedDescription))
        }
    }

    /// Hands the staged app to a detached installer and quits, so the swap happens while this
    /// process is not holding the bundle open.
    ///
    /// The previous bundle is kept until the new one proves it launched: the installer waits for the
    /// marker this launch would have cleared and puts the old app back if it never clears. An update
    /// that bricks the app leaves the user on the working version instead of nothing.
    @discardableResult
    static func replaceRunningApp(with staged: StagedUpdate) throws -> URL {
        let support = Self.applicationSupportDirectory().appendingPathComponent("Updates", isDirectory: true)
        let marker = support.appendingPathComponent("pending-install")
        let logURL = support.appendingPathComponent("install.log")
        let previous = staged.bundle.deletingLastPathComponent().appendingPathComponent("Previous.app")

        let scriptURL = support.appendingPathComponent("install-\(staged.version.description).sh")
        try Self.installerScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        // Recorded before the swap; the next successful launch deletes it.
        let record: [String: String] = ["version": staged.version.description, "previous": previous.path]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try data.write(to: marker, options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            Bundle.main.bundleURL.path,
            staged.bundle.path,
            previous.path,
            marker.path,
            logURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Give the installer a moment to attach before this process goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        return scriptURL
    }

    private static func installerScript() -> String {
        """
        # Written by Marquee's updater. Replaces the app bundle once the running copy has exited,
        # and puts the previous one back if the replacement never starts.
        set -uo pipefail
        TARGET="$1"; STAGED="$2"; PREVIOUS="$3"; MARKER="$4"; LOG="$5"; PID="$6"

        log() { printf '%s %s\\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

        sleep 0.3
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        log "installer running for $TARGET"

        if [ -e "$TARGET" ]; then
          rm -rf "$PREVIOUS"
          mv "$TARGET" "$PREVIOUS" || { log "could not move the old app aside"; exit 1; }
        fi
        if ! mv "$STAGED" "$TARGET"; then
          log "install failed; restoring"
          if [ -e "$PREVIOUS" ]; then mv "$PREVIOUS" "$TARGET"; fi
          open "$TARGET" 2>/dev/null || true
          exit 1
        fi

        log "installed; launching"
        open "$TARGET"

        # The new build deletes the marker as its first act. If it is still there after a minute,
        # that build never reached its own start-up, so the old one goes back.
        for _ in $(seq 1 60); do
          sleep 1
          if [ ! -e "$MARKER" ]; then log "new build started"; exit 0; fi
        done

        if [ -e "$PREVIOUS" ]; then
          log "new build did not start; rolling back"
          rm -rf "$TARGET"
          mv "$PREVIOUS" "$TARGET"
          open "$TARGET"
        else
          log "no previous build available to restore"
        fi
        """
    }

    /// Called once at launch. A marker still here means the app we are running is the one an
    /// installer just put in place, so it booted, and the old bundle is now dead weight.
    static func clearPendingInstallIfNeeded() {
        let support = Self.applicationSupportDirectory().appendingPathComponent("Updates", isDirectory: true)
        let marker = support.appendingPathComponent("pending-install")
        guard let data = try? Data(contentsOf: marker),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let previous = record["previous"]
        else {
            try? FileManager.default.removeItem(at: marker)
            return
        }
        try? FileManager.default.removeItem(at: marker)
        // Left behind if the installer script exited before it could; never blocks anything.
        try? FileManager.default.removeItem(atPath: previous)
    }

    func skipOfferedVersion() async {
        guard let release else { return }
        await checker?.skip(release.version)
        self.release = nil
        state = .idle
    }

    /// Abandons an in-flight download. The staged files are removed on the way out.
    func cancelInstall() {
        work?.cancel()
        work = nil
        staged?.cleanUp()
        staged = nil
        state = release == nil ? .idle : .available(release!.version)
    }

    func reset() async {
        staged?.cleanUp()
        staged = nil
        await checker?.reset()
        release = nil
        state = .idle
    }

    /// Shows the staged app in Finder without installing it — the escape hatch for a copy that
    /// can't replace itself, such as a build run from a worktree.
    func revealStagedApp() {
        guard let staged else { return }
        NSWorkspace.shared.activateFileViewerSelecting([staged.bundle])
    }

    // MARK: Paths

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Marquee", isDirectory: true)
    }

    private static func isInApplications(_ url: URL) -> Bool {
        url.path.hasPrefix("/Applications/") || url.path.hasPrefix("/System/Applications/")
    }

    private static func overrideFeedURL() -> URL? {
        let arguments = UserDefaults.standard.string(forKey: "updateFeedURL")
        guard let arguments, !arguments.isEmpty else { return nil }
        return URL(string: arguments)
    }
}