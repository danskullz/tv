import Foundation

/// Native site adapters included in Marquee's first-run source list.
public enum BuiltInProvider: String, Sendable, CaseIterable, Identifiable {
    case eztv
    case limeTorrents = "limetorrents"
    case solidTorrents = "solidtorrents"
    case pirateBay = "thepiratebay"
    case torrentProject = "torrentproject"
    case torrentsCSV = "torrentscsv"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .eztv: "EZTV"
        case .limeTorrents: "LimeTorrents"
        case .solidTorrents: "Solid Torrents"
        case .pirateBay: "The Pirate Bay"
        case .torrentProject: "TorrentProject"
        case .torrentsCSV: "torrents-csv"
        }
    }

    public var defaultURL: URL {
        switch self {
        case .eztv: URL(string: "https://eztvx.to")!
        case .limeTorrents: URL(string: "https://www.limetorrents.fun")!
        case .solidTorrents: URL(string: "https://solidtorrents.eu")!
        case .pirateBay: URL(string: "https://apibay.org")!
        case .torrentProject: URL(string: "https://torrentproject.se")!
        case .torrentsCSV: URL(string: "https://torrents-csv.com")!
        }
    }

    public var enabledByDefault: Bool { self != .torrentProject }

    /// The listed TorrentProject endpoint returned unrelated content during the 2026-10-09 check.
    public var defaultDisabledMessage: String? {
        self == .torrentProject ? "This provider's search endpoint did not return torrent results during setup." : nil
    }
}

/// Sources added once to a new database. Deleting one does not make it reappear next launch.
public enum DefaultIndexerProviders {
    public static let installedDefaultsKey = "indexers.defaultProvidersInstalled.v1"

    public static var records: [Indexer] {
        BuiltInProvider.allCases.map { provider in
            Indexer(
                id: stableID(provider.rawValue), name: provider.name, implementation: provider.rawValue,
                baseURL: provider.defaultURL.absoluteString, enabled: provider.enabledByDefault,
                minimumSeeders: 0, credentialRef: nil)
        } + [jackettRecord, prowlarrRecord, torlockRecord]
    }

    private static let jackettRecord = Indexer(
        id: stableID("jackett"), name: "Jackett", implementation: "jackett",
        baseURL: "http://127.0.0.1:9117/api/v2.0/indexers/all/results/torznab/api",
        enabled: false, minimumSeeders: 0,
        credentialRef: "indexer.\(stableID("jackett").uuidString.lowercased()).apikey")

    private static let prowlarrRecord = Indexer(
        id: stableID("prowlarr"), name: "Prowlarr", implementation: "prowlarr",
        baseURL: "http://127.0.0.1:9696", enabled: false, minimumSeeders: 0,
        credentialRef: "indexer.\(stableID("prowlarr").uuidString.lowercased()).apikey")

    private static let torlockRecord = Indexer(
        id: stableID("torlock"), name: "TorLock", implementation: "torlock",
        baseURL: "https://www.torlock.com/torznab/api", enabled: true, minimumSeeders: 0,
        credentialRef: nil)

    private static func stableID(_ key: String) -> UUID {
        let values: [String: String] = [
            "eztv": "89d5c8d2-a530-4be9-a1c2-599afba30101",
            "limetorrents": "89d5c8d2-a530-4be9-a1c2-599afba30102",
            "solidtorrents": "89d5c8d2-a530-4be9-a1c2-599afba30103",
            "thepiratebay": "89d5c8d2-a530-4be9-a1c2-599afba30104",
            "torrentproject": "89d5c8d2-a530-4be9-a1c2-599afba30105",
            "torrentscsv": "89d5c8d2-a530-4be9-a1c2-599afba30106",
            "jackett": "89d5c8d2-a530-4be9-a1c2-599afba30107",
            "prowlarr": "89d5c8d2-a530-4be9-a1c2-599afba30108",
            "torlock": "89d5c8d2-a530-4be9-a1c2-599afba30109",
        ]
        return UUID(uuidString: values[key]!)!
    }
}

/// Installs the provider catalog once; the marker also preserves a user's deletions.
public enum DefaultIndexerProviderSeeder {
    @discardableResult
    public static func installIfNeeded(
        into repository: any IndexerRepository, defaults: UserDefaults = .standard
    ) async throws -> Bool {
        guard !defaults.bool(forKey: DefaultIndexerProviders.installedDefaultsKey) else { return false }
        let existing = try await repository.all()
        var ids = Set(existing.map(\.id))
        var names = Set(existing.map { $0.name.lowercased() })
        for record in DefaultIndexerProviders.records {
            guard !ids.contains(record.id), !names.contains(record.name.lowercased()) else { continue }
            try await repository.upsert(record)
            ids.insert(record.id)
            names.insert(record.name.lowercased())
        }
        defaults.set(true, forKey: DefaultIndexerProviders.installedDefaultsKey)
        return true
    }
}
