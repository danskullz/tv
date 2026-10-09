import Foundation
import Testing

@testable import MarqueeCore

@Suite struct FileSafetyAndTransferTests {
    @Test func classifiesExtensionsAndRejectsDisguisedExecutables() throws {
        #expect(FileSafety.classify(fileName: "episode.MKV") == .media)
        #expect(FileSafety.classify(fileName: "episode.srt") == .subtitle)
        #expect(FileSafety.classify(fileName: "season.r03") == .archive)
        #expect(FileSafety.classify(fileName: "poster.jpg") == .ignored)
        if case .suspicious = FileSafety.classify(fileName: "payload.app") {} else { Issue.record("app bundle should be refused") }

        let dir = try transferTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disguised = dir.appendingPathComponent("payload.mp4")
        try Data([0x4d, 0x5a, 0x90, 0x00]).write(to: disguised)
        if case .suspicious = FileSafety.inspect(disguised) {} else { Issue.record("MZ signature should be refused") }
    }

    @Test func stagesCloneOrHardlinkThenPublishesWithoutReplacing() throws {
        let dir = try transferTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mkv")
        let destination = dir.appendingPathComponent("Library/movie.mkv")
        let contents = Data(repeating: 0x5a, count: 2_000_000)
        try contents.write(to: source)
        let transfer = FileTransfer()
        let volume = try source.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        if volume.volumeSupportsFileCloning == true {
            let clone = try transfer.stage(from: source, to: dir.appendingPathComponent("clone.mkv"), strategy: .clone)
            #expect(clone.method == .clone)
            try transfer.discard(clone)
        }
        let hardLink = try transfer.stage(from: source, to: dir.appendingPathComponent("hardlink.mkv"), strategy: .hardLink)
        #expect(hardLink.method == .hardLink)
        try transfer.discard(hardLink)

        let staged = try transfer.stage(from: source, to: destination)
        #expect(staged.method == .clone || staged.method == .hardLink)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try transfer.commit(staged)
        #expect(try Data(contentsOf: destination) == contents)
        #expect(FileManager.default.fileExists(atPath: source.path))

        let other = dir.appendingPathComponent("other.mkv")
        try Data("preserve".utf8).write(to: other)
        let collision = try transfer.stage(from: source, to: other, strategy: .copy)
        #expect(throws: FileTransferError.destinationExists) { try transfer.commit(collision) }
        try transfer.discard(collision)
        #expect(try String(contentsOf: other, encoding: .utf8) == "preserve")
    }

    @Test func copyReportsProgressAndMoveRequiresSeedingOptOut() throws {
        let dir = try transferTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mkv")
        let destination = dir.appendingPathComponent("copy.mkv")
        try Data(repeating: 0x42, count: 400_000).write(to: source)
        let transfer = FileTransfer()
        var lastProgress: FileTransferProgress?
        let copied = try transfer.stage(from: source, to: destination, strategy: .copy) { lastProgress = $0 }
        #expect(copied.method == .copy)
        #expect(lastProgress?.fraction == 1)
        try transfer.commit(copied)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))

        #expect(throws: FileTransferError.seedingMustBeDisabled) {
            _ = try transfer.stage(from: source, to: dir.appendingPathComponent("move.mkv"), strategy: .move, seeding: true)
        }
        let moved = try transfer.stage(
            from: source, to: dir.appendingPathComponent("move.mkv"), strategy: .move, seeding: false)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try transfer.discard(moved)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func trashCanBeRestoredWithoutOverwriting() throws {
        let dir = try transferTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("old.mkv")
        try Data("old".utf8).write(to: original)
        let transfer = FileTransfer()
        let receipt = try transfer.trash(original)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        try transfer.restore(receipt)
        #expect(try String(contentsOf: original, encoding: .utf8) == "old")
    }

    @Test func probeValidationRejectsMissingStreamsAndShortSamples() throws {
        let valid = MediaInfo(durationSeconds: 1_200, videoCodec: "h264", width: 1920, height: 1080)
        try MediaProbeValidation.validate(valid, expectedRuntimeSeconds: 1_200)
        #expect(throws: MediaProbeError.missingVideo) {
            try MediaProbeValidation.validate(MediaInfo(durationSeconds: 1_200), expectedRuntimeSeconds: nil)
        }
        do {
            try MediaProbeValidation.validate(
                MediaInfo(durationSeconds: 20, videoCodec: "h264", width: 640, height: 360),
                expectedRuntimeSeconds: 1_200)
            Issue.record("short samples should be rejected")
        } catch let error as MediaProbeError {
            if case .tooShort = error {} else { Issue.record("expected a short-duration verdict") }
        }
        try MediaProbeValidation.validateCodecClaim(.h264, against: "avc1")
        do {
            try MediaProbeValidation.validateCodecClaim(.h264, against: "hevc")
            Issue.record("mismatched claimed codec should be rejected")
        } catch let error as MediaProbeError {
            if case .codecMismatch(let claimed, let actual) = error {
                #expect(claimed == "h264" && actual == "hevc")
            } else {
                Issue.record("expected a codec mismatch verdict")
            }
        }
    }
}

private func transferTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-import-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
