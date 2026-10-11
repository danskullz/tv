import Foundation

/// Which builds a release offers.
public enum BuildArch: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64
    case universal

    /// The architecture to prefer on this Mac.
    ///
    /// A translation-aware binary reports `x86_64` for itself on Apple silicon, so asking the kernel
    /// about the *process* would hand Intel builds to every Rosetta user. `sysctl.proc_translated`
    /// is what tells the two apart; its absence on a real Intel Mac is the expected path.
    public static var host: BuildArch {
        #if arch(arm64)
        return .arm64
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let queried = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
        return queried && translated == 1 ? .arm64 : .x86_64
        #endif
    }

    /// Preference order for this Mac: its own architecture first, then `universal`.
    ///
    /// An Intel Mac is never offered an arm64 build. Rosetta runs x86_64 code on Apple silicon, so
    /// that pairing is one-directional — an arm64 fallback on an Intel host would be a build that
    /// cannot launch at all.
    public static func preference(for host: BuildArch) -> [BuildArch] {
        switch host {
        case .arm64: [.arm64, .x86_64, .universal]
        case .x86_64: [.x86_64, .universal]
        case .universal: [.universal]
        }
    }
}

/// Release track. `beta` is what the project's CI publishes today, so both are accepted by default.
public enum UpdateChannel: String, Codable, Sendable, CaseIterable {
    case stable
    case beta

    /// Whether a user who opts into one channel should also see the other.
    public static func isVisible(_ release: UpdateChannel, to preference: UpdateChannel) -> Bool {
        preference == .beta || release == preference
    }
}

/// One published version and the builds it offers.
public struct AppcastRelease: Sendable, Codable, Equatable, Identifiable {
    public var version: UpdateVersion
    public var channel: UpdateChannel
    public var publishedAt: Date?
    /// When set, clients older than this are not offered the release.
    public var minimumVersion: UpdateVersion?
    /// Withdrawn but still downloadable — for a bad build people are mid-download on.
    public var yanked: Bool
    /// Markdown release notes.
    public var notes: String?
    public var builds: [AppcastBuild]

    public var id: String { version.description }

    public init(
        version: UpdateVersion,
        channel: UpdateChannel = .beta,
        publishedAt: Date? = nil,
        minimumVersion: UpdateVersion? = nil,
        yanked: Bool = false,
        notes: String? = nil,
        builds: [AppcastBuild]
    ) {
        self.version = version
        self.channel = channel
        self.publishedAt = publishedAt
        self.minimumVersion = minimumVersion
        self.yanked = yanked
        self.notes = notes
        self.builds = builds
    }

    /// The build to install on this Mac, or nil when the release offers nothing we can run.
    public func build(for host: BuildArch = .host) -> AppcastBuild? {
        for arch in BuildArch.preference(for: host) {
            if let match = builds.first(where: { $0.arch == arch }) { return match }
        }
        return nil
    }
}

/// One downloadable archive: a Mac's worth of the app, pinned by content hash.
public struct AppcastBuild: Sendable, Codable, Equatable {
    public var arch: BuildArch
    public var url: URL
    /// Lowercase hex SHA-256 of the archive, as published in the signed manifest.
    public var sha256: String
    public var size: Int
    public var minOS: String?

    public init(arch: BuildArch, url: URL, sha256: String, size: Int, minOS: String? = nil) {
        self.arch = arch
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minOS = minOS
    }
}

/// The signed manifest at the update host.
///
/// `signatureURL` is only a hint about where to fetch the detached signature; it carries no trust on
/// its own, and a value pointing anywhere else is refused outright rather than fetched.
public struct Appcast: Sendable, Codable, Equatable {
    public static let supportedSchema = 1
    public static let bundleIdentifier = "com.danskullz.marquee"

    public var schema: Int
    public var app: String
    public var generatedAt: Date?
    public var signatureURL: URL?
    public var releases: [AppcastRelease]

    public init(
        schema: Int = supportedSchema,
        app: String = bundleIdentifier,
        generatedAt: Date? = nil,
        signatureURL: URL? = nil,
        releases: [AppcastRelease]
    ) {
        self.schema = schema
        self.app = app
        self.generatedAt = generatedAt
        self.signatureURL = signatureURL
        self.releases = releases
    }

    /// Rejects a manifest that is not ours or uses a shape we don't understand. Anything else would
    /// mean trusting fields we never read.
    public func validate() throws {
        guard schema == Self.supportedSchema else {
            throw UpdateError.unsupportedSchema(schema)
        }
        guard app == Self.bundleIdentifier else {
            throw UpdateError.foreignManifest(app)
        }
    }

    /// Newest first, whatever order the file arrived in.
    public var sortedReleases: [AppcastRelease] {
        releases.sorted { $0.version > $1.version }
    }

    /// The release this install should move to, or nil when it is current.
    ///
    /// Yanked releases are invisible; `minimumVersion` excludes clients too old to jump straight
    /// there; a skipped version silences every release up to and including it, so declining
    /// `0.1.30` doesn't immediately re-offer `0.1.29` on the next check.
    public func update(
        from current: UpdateVersion,
        channel: UpdateChannel = .beta,
        host: BuildArch = .host,
        skipping skipped: UpdateVersion? = nil
    ) -> AppcastRelease? {
        for release in sortedReleases {
            guard release.version > current else { break }
            guard !release.yanked else { continue }
            guard UpdateChannel.isVisible(release.channel, to: channel) else { continue }
            if let minimum = release.minimumVersion, current < minimum { continue }
            if let skipped, release.version <= skipped { continue }
            guard release.build(for: host) != nil else { continue }
            return release
        }
        return nil
    }
}

// MARK: - Decoding

extension UpdateVersion: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Appcast {
    /// Parses the manifest.
    ///
    /// Timestamps go through an explicit ISO 8601 parser rather than `JSONDecoder`'s built-in
    /// `.iso8601`, which accepts both `...09:00:00Z` and `...09:00:00.123Z` but only tries one
    /// shape, and whose exact behaviour has shifted between SDKs. Python's `datetime.isoformat()` —
    /// the obvious thing for a publisher to reach for — emits fractional seconds, so both shapes
    /// have to be understood, and anything else has to fail loudly rather than decode to a wrong
    /// instant.
    public static func decode(from data: Data) throws -> Appcast {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? iso8601WithFraction.parse(text) ?? iso8601WithoutFraction.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return try decoder.decode(Appcast.self, from: data)
    }

    private static let iso8601WithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601WithoutFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}