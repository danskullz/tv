import Foundation

/// A single search result from a Torznab indexer.
///
/// `downloadURL` / `magnetURL` may embed the indexer's API key (Jackett and Prowlarr proxy
/// downloads through themselves), so `description` redacts them. Treat both as secrets.
public struct IndexerRelease: Sendable, Hashable, Codable, Identifiable, CustomStringConvertible {
    public var indexerID: UUID
    public var indexerName: String
    public var title: String
    public var guid: String
    /// `.torrent` download link (or the indexer's proxy link).
    public var downloadURL: URL?
    public var magnetURL: URL?
    /// Lowercase hex (40 chars for v1, 64 for v2). Taken from the feed, else derived from the magnet link.
    public var infoHash: String?
    /// Details page on the indexer's site.
    public var infoURL: URL?
    public var size: Int64?
    public var seeders: Int?
    /// Raw Torznab `peers` value; by convention this is seeders + leechers.
    public var peers: Int?
    /// Explicit `leechers`, else `peers - seeders` when both are known.
    public var leechers: Int?
    public var grabs: Int?
    public var files: Int?
    public var publishDate: Date?
    public var categories: [Int]
    /// Normalised to `tt` + digits.
    public var imdbID: String?
    public var tvdbID: Int?
    public var tmdbID: Int?
    /// 0 = freeleech, 0.5 = half, 1 = normal; nil when the indexer doesn't say.
    public var downloadVolumeFactor: Double?
    public var uploadVolumeFactor: Double?
    public var minimumRatio: Double?
    /// Seconds.
    public var minimumSeedTime: TimeInterval?
    /// Flags reported by the source, such as `Freeleech` or `Halfleech`.
    public var indexerFlags: [String]
    /// Other indexers that returned the same release (filled by deduplication).
    public var alsoFoundOn: [UUID]

    public var id: String { "\(indexerID.uuidString.lowercased()):\(guid)" }

    public init(
        indexerID: UUID,
        indexerName: String = "",
        title: String,
        guid: String,
        downloadURL: URL? = nil,
        magnetURL: URL? = nil,
        infoHash: String? = nil,
        infoURL: URL? = nil,
        size: Int64? = nil,
        seeders: Int? = nil,
        peers: Int? = nil,
        leechers: Int? = nil,
        grabs: Int? = nil,
        files: Int? = nil,
        publishDate: Date? = nil,
        categories: [Int] = [],
        imdbID: String? = nil,
        tvdbID: Int? = nil,
        tmdbID: Int? = nil,
        downloadVolumeFactor: Double? = nil,
        uploadVolumeFactor: Double? = nil,
        minimumRatio: Double? = nil,
        minimumSeedTime: TimeInterval? = nil,
        indexerFlags: [String] = [],
        alsoFoundOn: [UUID] = []
    ) {
        self.indexerID = indexerID
        self.indexerName = indexerName
        self.title = title
        self.guid = guid
        self.downloadURL = downloadURL
        self.magnetURL = magnetURL
        self.infoHash = infoHash
        self.infoURL = infoURL
        self.size = size
        self.seeders = seeders
        self.peers = peers
        self.leechers = leechers
        self.grabs = grabs
        self.files = files
        self.publishDate = publishDate
        self.categories = categories
        self.imdbID = imdbID
        self.tvdbID = tvdbID
        self.tmdbID = tmdbID
        self.downloadVolumeFactor = downloadVolumeFactor
        self.uploadVolumeFactor = uploadVolumeFactor
        self.minimumRatio = minimumRatio
        self.minimumSeedTime = minimumSeedTime
        self.indexerFlags = indexerFlags
        self.alsoFoundOn = alsoFoundOn
    }

    public var isFreeleech: Bool { downloadVolumeFactor == 0 }

    /// Safe for logs: links are redacted and never printed in full.
    public var description: String {
        let link = downloadURL.map { SecretRedactor.redact($0) } ?? (magnetURL != nil ? "magnet" : "no link")
        return "IndexerRelease(\(title), \(indexerName), seeders: \(seeders.map(String.init) ?? "?"), \(link))"
    }
}

/// Info-hash helpers: validation, base32 -> hex and magnet extraction.
public enum InfoHash {
    /// Returns lowercase hex for a 40/64-char hex string or a 32-char base32 string, else nil.
    public static func normalize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHex: (String) -> Bool = { s in s.allSatisfy { $0.isHexDigit && $0.isASCII } }
        if (value.count == 40 || value.count == 64), isHex(value) { return value.lowercased() }
        if value.count == 32, let bytes = base32Decode(value.uppercased()) {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    /// Extracts the `xt=urn:btih:` hash from a magnet link.
    public static func fromMagnet(_ magnet: String) -> String? {
        guard let question = magnet.firstIndex(of: "?") else { return nil }
        for part in magnet[magnet.index(after: question)...].split(separator: "&") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            guard part[..<eq].lowercased() == "xt" else { continue }
            let value = String(part[part.index(after: eq)...]).removingPercentEncoding ?? String(part[part.index(after: eq)...])
            let prefix = "urn:btih:"
            if value.lowercased().hasPrefix(prefix) {
                return normalize(String(value.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func base32Decode(_ s: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits: UInt64 = 0
        var bitCount = 0
        var out: [UInt8] = []
        for ch in s {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            bits = (bits << 5) | UInt64(idx)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                out.append(UInt8((bits >> UInt64(bitCount)) & 0xFF))
            }
        }
        return out.count == 20 ? out : nil
    }
}
