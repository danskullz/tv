import Foundation
import Testing
@testable import MarqueeCore

/// What stands between a downloaded zip and the app that replaces the running one.
@Suite("Update installer")
struct UpdateInstallerTests {
    private let installer = UpdateInstaller(requirement: nil)

    // MARK: Checksum

    @Test func aMatchingChecksumIsAccepted() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let file = scratch.appendingPathComponent("build.zip")
        let contents = Data(repeating: 0xA5, count: 4096)
        try contents.write(to: file)

        let build = UpdatesManifest.build(.arm64, version: "0.1.30", size: 4096, sha256: UpdatesSigning.sha256Hex(contents))
        #expect(throws: Never.self) { try self.installer.verifyChecksum(of: file, expected: build) }
    }

    @Test func aChangedByteIsCaught() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let file = scratch.appendingPathComponent("build.zip")
        let original = Data(repeating: 0xA5, count: 1024)
        try original.write(to: file)

        let build = UpdatesManifest.build(.arm64, sha256: UpdatesSigning.sha256Hex(original))
        var tampered = original
        tampered[500] = 0xA4
        try tampered.write(to: file)

        #expect(throws: UpdateError.self) { try self.installer.verifyChecksum(of: file, expected: build) }
    }

    @Test func aChecksumOfTheWrongShapeNeverMatches() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let file = scratch.appendingPathComponent("build.zip")
        try Data(repeating: 1, count: 16).write(to: file)

        let build = UpdatesManifest.build(.arm64, sha256: "not-a-hash")
        #expect(throws: UpdateError.self) { try self.installer.verifyChecksum(of: file, expected: build) }
    }

    // MARK: Bundle identity

    /// Builds a minimal but structurally real `.app` so identity checks have something to read.
    private func makeApp(
        at root: URL,
        identifier: String = Appcast.bundleIdentifier,
        version: String = "0.1.30",
        withExecutable: Bool = true
    ) throws -> URL {
        let app = root.appendingPathComponent("Marquee.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Marquee",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if withExecutable {
            let binary = contents.appendingPathComponent("MacOS/Marquee")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return app
    }

    @Test func aBundleThatSaysItIsTheRightVersionPasses() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let app = try makeApp(at: scratch)

        #expect(throws: Never.self) {
            try BundleValidation.validateIdentity(
                of: app,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }
    }

    @Test func aBundleClaimingADifferentVersionIsRefused() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let app = try makeApp(at: scratch, version: "0.1.29")

        // The zip may have been swapped for an older one even though its name says otherwise.
        #expect(throws: UpdateError.self) {
            try BundleValidation.validateIdentity(
                of: app,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }
    }

    @Test func aBundleForAnotherAppIsRefused() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let app = try makeApp(at: scratch, identifier: "com.example.something-else")

        #expect(throws: UpdateError.bundleMismatch("it's com.example.something-else")) {
            try BundleValidation.validateIdentity(
                of: app,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }
    }

    @Test func anAppWithNoInfoPlistOrNoBinaryIsRefused() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }

        let empty = scratch.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: UpdateError.self) {
            try BundleValidation.validateIdentity(
                of: empty,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }

        let noBinary = try makeApp(at: scratch.appendingPathComponent("second"), withExecutable: false)
        #expect(throws: UpdateError.self) {
            try BundleValidation.validateIdentity(
                of: noBinary,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }
    }

    // MARK: Code signature

    @Test func anAdHocSignedBundleIsStructurallyValidButFailsADeveloperIDRequirement() throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
                     "codesign is not present")
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let app = try makeApp(at: scratch)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", app.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #expect(codesign.terminationStatus == 0, "could not ad-hoc sign the fixture bundle")

        // Today's reality: nothing is Developer ID signed, so the signature is checked for
        // integrity only.
        #expect(throws: Never.self) {
            try BundleValidation.validateSignature(of: app, requirement: nil)
        }
        // The rule a released build is held to pins the signing identity, and an ad-hoc signature
        // has none — so it is rejected before it can ever be installed.
        let requirement = BundleValidation.requirement(
            bundleIdentifier: Appcast.bundleIdentifier, teamIdentifier: "ABCDE12345")
        #expect(throws: UpdateError.self) {
            try BundleValidation.validateSignature(of: app, requirement: requirement)
        }
    }

    @Test func theRequirementNamesTheBundleAndTheTeam() {
        let bare = BundleValidation.requirement(
            bundleIdentifier: "com.danskullz.marquee", teamIdentifier: nil)
        #expect(bare == "anchor apple generic and identifier \"com.danskullz.marquee\"")
        let pinned = BundleValidation.requirement(
            bundleIdentifier: "com.danskullz.marquee", teamIdentifier: "ABCDE12345")
        #expect(pinned.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        // An empty team must not produce a rule that matches everything.
        #expect(BundleValidation.requirement(bundleIdentifier: "x", teamIdentifier: "")
            == "anchor apple generic and identifier \"x\"")
    }

    // MARK: Free space

    @Test func freeSpaceResolvesToTheNearestExistingAncestor() throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let deep = scratch.appendingPathComponent("a/b/c/d", isDirectory: true)

        let space = try #require(UpdateInstaller.freeSpace(at: deep))
        #expect(space > 0)
        // Both resolve to the same volume, so the answers are the same number minus whatever else
        // the machine did in between — compared with slack rather than for exact equality.
        let fromRoot = try #require(UpdateInstaller.freeSpace(at: scratch))
        #expect(abs(space - fromRoot) < 64 * 1024 * 1024)
    }

    // MARK: Extraction

    @Test func dittoUnpacksARealArchive() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto"),
                     "ditto is not present")
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }

        let source = scratch.appendingPathComponent("src/Marquee.app", isDirectory: true)
        try makeApp(at: scratch.appendingPathComponent("src"))

        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", source.path, scratch.appendingPathComponent("out.zip").path]
        pack.standardOutput = FileHandle.nullDevice
        pack.standardError = FileHandle.nullDevice
        try pack.run()
        pack.waitUntilExit()
        try #expect(pack.terminationStatus == 0)

        let unpacked = scratch.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await Unarchiver.dittoExtract(scratch.appendingPathComponent("out.zip"), into: unpacked)

        let extracted = unpacked.appendingPathComponent("Marquee.app")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        #expect(throws: Never.self) {
            try BundleValidation.validateIdentity(
                of: extracted,
                expectedBundleIdentifier: Appcast.bundleIdentifier,
                expectedVersion: UpdateVersion("0.1.30"))
        }
    }

    @Test func extractingSomethingThatIsNotAZipFails() async throws {
        let scratch = try makeUpdatesScratchDirectory()
        defer { removeUpdatesScratchDirectory(scratch) }
        let junk = scratch.appendingPathComponent("junk.zip")
        try Data("definitely not a zip".utf8).write(to: junk)

        await #expect(throws: UpdateError.self) {
            try await Unarchiver.dittoExtract(junk, into: scratch.appendingPathComponent("out"))
        }
    }
}