import CryptoKit
import Foundation

/// A downloaded, unpacked, verified app bundle sitting on disk, ready to be swapped in.
public struct StagedUpdate: Sendable, Equatable {
    public let version: UpdateVersion
    public let build: AppcastBuild
    /// The archive as downloaded. Kept until the swap succeeds, so a failed install can be retried
    /// without going back to the network.
    public let archive: URL
    /// The verified `.app` inside a scratch directory.
    public let bundle: URL
    /// The scratch directory holding `bundle`; deleting it removes the staged app.
    public let scratch: URL

    /// Removes everything this staging step created.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: archive)
    }
}

/// Runs an update as far as it can go without quitting: fetch, verify, unpack, check.
///
/// The swap itself is left to the caller. Replacing `/Applications/Marquee.app` means this process
/// has to exit first, and the thing doing that needs AppKit, so the boundary is drawn here.
public struct UpdateInstaller: Sendable {
    public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

    /// The app name and identifier of the running copy. Passed in so tests don't need a real bundle.
    public let bundleIdentifier: String
    public let appName: String
    /// Pinned signing rule, or nil while the project is ad-hoc signed.
    public let requirement: String?

    private let downloader: UpdateDownloader

    public init(
        bundleIdentifier: String = Appcast.bundleIdentifier,
        appName: String = "Marquee",
        requirement: String? = nil,
        downloader: UpdateDownloader = UpdateDownloader()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.requirement = requirement
        self.downloader = downloader
    }

    /// The rule the running copy should be held to. Reads the signing team the bundle was built with,
/// so this stays correct the day `bundle.sh` starts writing a Developer ID team into Info.plist.
    public static func requirementForRunningApp(
        bundleIdentifier: String = Appcast.bundleIdentifier
    ) -> String {
        BundleValidation.requirement(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: AppInfo.developerTeamIdentifier)
    }

    /// Downloads, verifies and unpacks one build into `scratchRoot`.
    ///
    /// - Parameter progress: called off the main actor; hop before touching UI.
    public func stage(
        _ build: AppcastBuild,
        version: UpdateVersion,
        scratchRoot: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> StagedUpdate {
        try requireRoom(for: build, in: scratchRoot)

        let scratch = scratchRoot.appendingPathComponent("stage-\(version.description)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var archive: URL?
        do {
            progress(.downloading(0))
            let downloaded = try await downloader.download(build.url) { fraction in
                progress(.downloading(fraction))
            }
            archive = downloaded

            progress(.verifying(0))
            try verifyChecksum(of: downloaded, expected: build)
            if build.size > 0 {
                let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
                guard size == build.size else {
                    throw UpdateError.incompleteDownload(expected: build.size, received: size)
                }
            }

            progress(.unpacking)
            let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await Unarchiver.dittoExtract(downloaded, into: unpacked)

            progress(.checking)
            let app = try locateAppBundle(in: unpacked)
            try BundleValidation.validateIdentity(
                of: app, expectedBundleIdentifier: bundleIdentifier, expectedVersion: version)
            try BundleValidation.validateSignature(of: app, requirement: requirement)

            progress(.ready)
            return StagedUpdate(version: version, build: build, archive: downloaded, bundle: app, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            if let archive { try? FileManager.default.removeItem(at: archive) }
            if error is CancellationError { throw UpdateError.cancelled }
            throw error
        }
    }

    /// Content hash against the value in the signed manifest. This is the gate that stops a
    /// tampered server handing over a zip the signature can't vouch for.
    public func verifyChecksum(of file: URL, expected: AppcastBuild) throws {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expected.sha256) == .orderedSame else {
            throw UpdateError.checksumMismatch(expected: expected.sha256, actual: digest)
        }
    }

    private func locateAppBundle(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let expected = directory.appendingPathComponent("\(appName).app")
        if fm.fileExists(atPath: expected.path) { return expected }
        // Tolerate a zip that nested the app one level deeper, rather than failing a valid update.
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "app" && entry.lastPathComponent.hasPrefix(appName) {
                return entry
            }
        }
        throw UpdateError.missingAppBundle("No \(appName).app inside the download.")
    }

    /// The archive plus its expansion both have to fit before anything is downloaded.
    private func requireRoom(for build: AppcastBuild, in directory: URL) throws {
        guard build.size > 0 else { return }
        // Archives hold several times their size once expanded; the floor covers metadata and the
        // previous staging directory.
        let needed = Int64(build.size) * 3 + 64 * 1024 * 1024
        // An unreadable volume isn't a reason to refuse; finding out the hard way is recoverable.
        guard let available = Self.freeSpace(at: directory) else { return }
        guard available >= needed else {
            throw UpdateError.insufficientSpace(needed: needed, available: available)
        }
    }

    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// What the installer is doing, for the progress sheet.
public enum DownloadProgress: Sendable, Equatable {
    case downloading(Double)
    case verifying(Double)
    case unpacking
    case checking
    case ready
}

/// Expands the `.zip` the release pipeline produces.
///
/// `/usr/bin/ditto` is Apple's own unpacker, present on every Mac, and preserves the symlinks and
/// extended attributes a signed bundle needs. Run with an argument array, never a shell string, so
/// nothing in the path is ever interpreted.
enum Unarchiver {
    static func dittoExtract(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: UpdateError.corruptArchive(
                                "ditto exited with status \(process.terminationStatus)."))
                    }
                }
                do { try process.run() } catch {
                    continuation.resume(throwing: UpdateError.corruptArchive(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}