import Foundation

/// Result of parsing a Torznab RSS feed.
public struct TorznabParsedFeed: Sendable, Equatable {
    public var releases: [IndexerRelease]
    /// Items dropped because they had no title or no way to download them.
    public var skippedItems: Int
    /// True when the XML was cut off or malformed part-way and only the complete items before the damage were kept.
    public var isPartial: Bool
    /// `<newznab:response total= offset=>` when present.
    public var total: Int?
    public var offset: Int?
}

public enum TorznabResultParser {
    /// Parses a Torznab/RSS search response.
    ///
    /// - Throws: `IndexerError.apiError` / `.authenticationFailed` for `<error/>` bodies and
    ///   `.malformedResponse` when nothing usable could be read. A feed that breaks after at least one
    ///   complete item yields those items with `isPartial == true` instead of failing.
    public static func parse(_ data: Data, indexerID: UUID, indexerName: String = "") throws -> TorznabParsedFeed {
        try TorznabXMLPreflight.check(data)
        let delegate = FeedDelegate(indexerID: indexerID, indexerName: indexerName)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()

        if let (code, description) = delegate.apiError {
            throw IndexerError.fromAPIError(code: code, description: description)
        }
        if let root = delegate.rootName, root != "rss", root != "feed" {
            throw IndexerError.malformedResponse("Expected a Torznab RSS feed but received <\(root)>.")
        }
        if !ok {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            if delegate.releases.isEmpty && delegate.skipped == 0 {
                throw IndexerError.malformedResponse("The search results are not valid XML: \(reason).")
            }
            return TorznabParsedFeed(
                releases: delegate.releases, skippedItems: delegate.skipped, isPartial: true,
                total: delegate.total, offset: delegate.offset)
        }
        return TorznabParsedFeed(
            releases: delegate.releases, skippedItems: delegate.skipped, isPartial: false,
            total: delegate.total, offset: delegate.offset)
    }

    // MARK: - Delegate

    private struct RawItem {
        var title = ""
        var guid = ""
        var link = ""
        var comments = ""
        var pubDate = ""
        var size = ""
        var categoryTexts: [String] = []
        var enclosureURL = ""
        var enclosureLength = ""
        var attrs: [(name: String, value: String)] = []
    }

    private final class FeedDelegate: NSObject, XMLParserDelegate {
        let indexerID: UUID
        let indexerName: String
        let dates = TorznabDateParser()

        var rootName: String?
        var apiError: (Int, String)?
        var releases: [IndexerRelease] = []
        var skipped = 0
        var total: Int?
        var offset: Int?

        private var depth = 0
        private var itemDepth: Int?
        private var item = RawItem()
        private var text = ""

        init(indexerID: UUID, indexerName: String) {
            self.indexerID = indexerID
            self.indexerName = indexerName
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            text = ""
            let name = TorznabXMLNames.local(elementName)
            if rootName == nil {
                rootName = name
                if name == "error" {
                    apiError = (Int(attributeDict["code"] ?? "") ?? 900, attributeDict["description"] ?? "")
                    parser.abortParsing()
                    return
                }
            }
            if itemDepth == nil {
                if name == "item" || name == "entry" {
                    itemDepth = depth
                    item = RawItem()
                } else if name == "response" {
                    total = Int(attributeDict["total"] ?? "")
                    offset = Int(attributeDict["offset"] ?? "")
                }
                return
            }
            guard depth == (itemDepth ?? 0) + 1 else { return }
            switch name {
            case "attr":
                if let n = attributeDict["name"], let v = attributeDict["value"] {
                    item.attrs.append((n.lowercased(), v))
                }
            case "enclosure":
                item.enclosureURL = attributeDict["url"] ?? ""
                item.enclosureLength = attributeDict["length"] ?? ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard itemDepth != nil else { return }
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard itemDepth != nil else { return }
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            defer { depth -= 1 }
            guard let itemDepth else { return }
            let name = TorznabXMLNames.local(elementName)
            if depth == itemDepth {
                finishItem()
                self.itemDepth = nil
                return
            }
            guard depth == itemDepth + 1 else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": item.title = value
            case "guid": item.guid = value
            case "link": item.link = value
            case "comments": item.comments = value
            case "pubdate", "published", "updated": if item.pubDate.isEmpty { item.pubDate = value }
            case "size": item.size = value
            case "category": if !value.isEmpty { item.categoryTexts.append(value) }
            default: break
            }
        }

        private func finishItem() {
            if let release = makeRelease(from: item) {
                releases.append(release)
            } else {
                skipped += 1
            }
        }

        private func makeRelease(from raw: RawItem) -> IndexerRelease? {
            func attrs(_ name: String) -> [String] { raw.attrs.filter { $0.name == name }.map(\.value) }
            func attr(_ name: String) -> String? { attrs(name).first }
            func int(_ s: String?) -> Int? {
                guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
                return Int(s) ?? Double(s).flatMap { $0.isFinite ? Int($0) : nil }
            }
            func double(_ s: String?) -> Double? {
                guard let s = s?.trimmingCharacters(in: .whitespaces), let d = Double(s), d.isFinite else { return nil }
                return d
            }
            func url(_ s: String?) -> URL? {
                guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return URL(string: s)
            }

            let title = raw.title
            guard !title.isEmpty else { return nil }

            let candidates = [attr("magneturl"), raw.link, raw.enclosureURL, raw.guid]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let magnetString = candidates.first { $0.lowercased().hasPrefix("magnet:") }
            let downloadString = [raw.enclosureURL, raw.link]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }

            var infoHash = attr("infohash").flatMap(InfoHash.normalize)
            if infoHash == nil, let magnetString { infoHash = InfoHash.fromMagnet(magnetString) }

            var magnetURL = url(magnetString)
            let downloadURL = url(downloadString)
            if magnetURL == nil, downloadURL == nil, let infoHash {
                // Feed carries a hash but no link; a magnet built from it is enough to download.
                let name = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                magnetURL = URL(string: "magnet:?xt=urn:btih:\(infoHash)&dn=\(name)")
            }
            guard magnetURL != nil || downloadURL != nil else { return nil }

            let size = (int(attr("size")) ?? int(raw.size) ?? int(raw.enclosureLength)).map(Int64.init)
            let seeders = int(attr("seeders"))
            let peers = int(attr("peers"))
            var leechers = int(attr("leechers"))
            if leechers == nil, let seeders, let peers { leechers = max(0, peers - seeders) }

            var categories: [Int] = []
            for value in attrs("category") + raw.categoryTexts {
                if let c = Int(value.trimmingCharacters(in: .whitespaces)), !categories.contains(c) { categories.append(c) }
            }

            let published = [attr("publishdate"), raw.pubDate].compactMap { $0 }.lazy.compactMap { self.dates.parse($0) }.first

            let guid = raw.guid.isEmpty ? (raw.link.isEmpty ? title : raw.link) : raw.guid

            return IndexerRelease(
                indexerID: indexerID,
                indexerName: indexerName,
                title: title,
                guid: guid,
                downloadURL: downloadURL,
                magnetURL: magnetURL,
                infoHash: infoHash,
                infoURL: url(raw.comments),
                size: size,
                seeders: seeders,
                peers: peers,
                leechers: leechers,
                grabs: int(attr("grabs")),
                files: int(attr("files")),
                publishDate: published,
                categories: categories,
                imdbID: Self.normalizeIMDb(attr("imdbid") ?? attr("imdb")),
                tvdbID: int(attr("tvdbid")),
                tmdbID: int(attr("tmdbid")),
                downloadVolumeFactor: double(attr("downloadvolumefactor")),
                uploadVolumeFactor: double(attr("uploadvolumefactor")),
                minimumRatio: double(attr("minimumratio")),
                minimumSeedTime: double(attr("minimumseedtime")))
        }

        static func normalizeIMDb(_ raw: String?) -> String? {
            guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
            if s.hasPrefix("tt") { s.removeFirst(2) }
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n > 0 else { return nil }
            return "tt" + String(repeating: "0", count: max(0, 7 - s.count)) + s
        }
    }
}

/// Parses the date formats seen in Torznab feeds (RFC 822 variants and ISO 8601).
/// Instances hold formatters, so create one per parse and don't share across threads.
final class TorznabDateParser {
    private let formatters: [DateFormatter]
    private let iso = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter

    init() {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        formatters = patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            return f
        }
        isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: s) { return date }
        }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }
}
