import CryptoKit
import Darwin
import Foundation

/// How an import is materialized in the library.
public enum FileTransferStrategy: Sendable, Hashable {
    /// Clone on the same clone-capable volume, otherwise link on-volume or copy across volumes.
    case automatic
    case clone
    case hardLink
    case copy
    /// Only valid when the caller has explicitly chosen not to keep seeding.
    case move
}

public enum FileTransferMethod: String, Sendable, Hashable {
    case clone, hardLink, copy, move
}

public struct FileTransferProgress: Sendable, Hashable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 1 }
}

public struct StagedFileTransfer: Sendable, Hashable {
    public var source: URL
    public var destination: URL
    /// Temporary file in the destination directory. It retains the destination's extension for probing.
    public var stagedURL: URL
    public var method: FileTransferMethod
    public var size: Int64
}

public struct TrashedFile: Codable, Sendable, Hashable {
    public var originalURL: URL
    public var trashedURL: URL
}

public enum FileTransferError: Error, Sendable, Equatable {
    case sourceMissing
    case destinationExists
    case crossVolume
    case cloneUnavailable(String)
    case notEnoughSpace(required: Int64, available: Int64)
    case sizeMismatch
    case checksumMismatch
    case seedingMustBeDisabled
    case moveRestoreFailed
    case filesystem(String)
}

/// Stages and verifies files before atomically publishing them. Existing destination files are never overwritten.
public struct FileTransfer: Sendable {
    public init() {}

    public func stage(
        from source: URL, to destination: URL, strategy: FileTransferStrategy = .automatic,
        seeding: Bool = true, progress: (FileTransferProgress) -> Void = { _ in }
    ) throws -> StagedFileTransfer {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw FileTransferError.sourceMissing }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attributes = try fm.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sourceVolume = try volume(for: source)
        let destinationVolume = try volume(for: destination.deletingLastPathComponent())
        let sameVolume = sourceVolume.id.isEqual(destinationVolume.id)
        let candidates: [FileTransferMethod]
        if strategy == .automatic {
            if sameVolume {
                candidates = sourceVolume.supportsCloning && destinationVolume.supportsCloning
                    ? [.clone, .hardLink, .copy] : [.hardLink, .copy]
            } else {
                candidates = [.copy]
            }
        } else {
            candidates = [try method(
                strategy, sameVolume: sameVolume, sourceSupportsCloning: sourceVolume.supportsCloning,
                destinationSupportsCloning: destinationVolume.supportsCloning, seeding: seeding)]
        }

        let suffix = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let tempName = ".\(stem).marquee-\(UUID().uuidString).partial" + (suffix.isEmpty ? "" : ".\(suffix)")
        let stagedURL = destination.deletingLastPathComponent().appendingPathComponent(tempName)
        var lastError: Error?
        for chosen in candidates {
            do {
                switch chosen {
                case .clone:
                    guard clonefile(source.path, stagedURL.path, 0) == 0 else {
                        throw FileTransferError.cloneUnavailable(String(cString: strerror(errno)))
                    }
                case .hardLink:
                    guard link(source.path, stagedURL.path) == 0 else {
                        if errno == EXDEV { throw FileTransferError.crossVolume }
                        throw FileTransferError.filesystem(String(cString: strerror(errno)))
                    }
                case .copy:
                    try ensureFreeSpace(size, at: destination.deletingLastPathComponent())
                    try copyWithProgress(from: source, to: stagedURL, size: size, progress: progress)
                    let stagedAttributes = try fm.attributesOfItem(atPath: stagedURL.path)
                    guard (stagedAttributes[.size] as? NSNumber)?.int64Value == size else {
                        throw FileTransferError.sizeMismatch
                    }
                    guard try sampledDigest(of: source, size: size) == sampledDigest(of: stagedURL, size: size) else {
                        throw FileTransferError.checksumMismatch
                    }
                case .move:
                    try fm.moveItem(at: source, to: stagedURL)
                }
                let stagedAttributes = try fm.attributesOfItem(atPath: stagedURL.path)
                guard (stagedAttributes[.size] as? NSNumber)?.int64Value == size else {
                    throw FileTransferError.sizeMismatch
                }
                return StagedFileTransfer(
                    source: source, destination: destination, stagedURL: stagedURL, method: chosen, size: size)
            } catch {
                lastError = error
                if chosen == .move, fm.fileExists(atPath: stagedURL.path), !fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: stagedURL, to: source)
                } else {
                    try? fm.removeItem(at: stagedURL)
                }
                guard strategy == .automatic else { throw error }
            }
        }
        throw lastError ?? FileTransferError.filesystem("Couldn't stage the file.")
    }

    /// Publishes a verified staged file with a no-replace atomic link/unlink in the same directory.
    public func commit(_ staged: StagedFileTransfer) throws {
        guard !FileManager.default.fileExists(atPath: staged.destination.path) else {
            throw FileTransferError.destinationExists
        }
        guard link(staged.stagedURL.path, staged.destination.path) == 0 else {
            if errno == EEXIST { throw FileTransferError.destinationExists }
            throw FileTransferError.filesystem(String(cString: strerror(errno)))
        }
        guard unlink(staged.stagedURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staged.destination)
            throw FileTransferError.filesystem(String(cString: strerror(code)))
        }
    }

    /// Clears quarantine metadata from a verified media stage. This never changes the file's executable bit.
    public func clearQuarantine(_ url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", 0)
    }

    /// Removes an unpublished stage. A moved source is put back when possible.
    public func discard(_ staged: StagedFileTransfer) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.stagedURL.path) else { return }
        if staged.method == .move {
            guard !fm.fileExists(atPath: staged.source.path) else { throw FileTransferError.moveRestoreFailed }
            try fm.moveItem(at: staged.stagedURL, to: staged.source)
        } else {
            try fm.removeItem(at: staged.stagedURL)
        }
    }

    /// Sends a verified old file to the user's Trash. It is never unlinked permanently.
    public func trash(_ url: URL) throws -> TrashedFile {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashedURL = trashed as URL? else {
            throw FileTransferError.filesystem("The system didn't report where the trashed file went.")
        }
        return TrashedFile(originalURL: url, trashedURL: trashedURL)
    }

    /// Restores a trashed file without replacing anything at its former path.
    public func restore(_ trashed: TrashedFile) throws {
        guard !FileManager.default.fileExists(atPath: trashed.originalURL.path) else {
            throw FileTransferError.destinationExists
        }
        try FileManager.default.moveItem(at: trashed.trashedURL, to: trashed.originalURL)
    }

    private func method(
        _ requested: FileTransferStrategy, sameVolume: Bool, sourceSupportsCloning: Bool,
        destinationSupportsCloning: Bool, seeding: Bool
    ) throws -> FileTransferMethod {
        switch requested {
        case .automatic:
            if sameVolume, sourceSupportsCloning, destinationSupportsCloning { return .clone }
            return sameVolume ? .hardLink : .copy
        case .clone:
            guard sameVolume else { throw FileTransferError.crossVolume }
            guard sourceSupportsCloning, destinationSupportsCloning else { throw FileTransferError.cloneUnavailable("The volume doesn't support APFS cloning.") }
            return .clone
        case .hardLink:
            guard sameVolume else { throw FileTransferError.crossVolume }
            return .hardLink
        case .copy: return .copy
        case .move:
            guard !seeding else { throw FileTransferError.seedingMustBeDisabled }
            return .move
        }
    }

    private func volume(for url: URL) throws -> (id: NSObject, supportsCloning: Bool) {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey, .volumeSupportsFileCloningKey])
        guard let id = values.volumeIdentifier as? NSObject else {
            throw FileTransferError.filesystem("Couldn't identify the storage volume.")
        }
        return (id, values.volumeSupportsFileCloning ?? false)
    }

    private func ensureFreeSpace(_ required: Int64, at directory: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw FileTransferError.filesystem("Couldn't check the destination's free space.")
        }
        guard available >= required else { throw FileTransferError.notEnoughSpace(required: required, available: available) }
    }

    private func copyWithProgress(
        from source: URL, to destination: URL, size: Int64,
        progress: (FileTransferProgress) -> Void
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        let output = FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard output else { try? input.close(); throw FileTransferError.filesystem("Couldn't create a temporary import file.") }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? writer.close() }
        let chunkSize = 8 << 20
        var done: Int64 = 0
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
            done += Int64(chunk.count)
            progress(FileTransferProgress(completedBytes: done, totalBytes: size))
        }
        try writer.synchronize()
    }

    private func sampledDigest(of url: URL, size: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        let sampleSize = 64 * 1024
        let offsets: [UInt64] = [0, UInt64(max(0, size / 2 - Int64(sampleSize / 2))), UInt64(max(0, size - Int64(sampleSize)))]
        for offset in offsets {
            try handle.seek(toOffset: offset)
            hash.update(data: try handle.read(upToCount: sampleSize) ?? Data())
        }
        return Data(hash.finalize())
    }
}
