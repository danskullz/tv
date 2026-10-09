import Foundation
import Synchronization

/// One release in the demo catalogue.
struct DemoRelease: Sendable {
    enum Kind: Sendable { case tv, movie }
    var kind: Kind
    var title: String
    var guid: String
    var infoHash: String
    var size: Int64
    var seeders: Int
    var magnet: String
    var season: Int?
    var episode: Int?
}

/// A local Torznab indexer (loopback only) serving a fixed catalogue. It only ever advertises the
/// synthetic demo releases, so the add -> search -> grab -> stream flow runs with no outside sources.
final class TorznabFixtureServer: Sendable {
    static let seriesName = "marquee test pattern"
    static let movieName = "marquee demo reel"

    private let server: LoopbackHTTPServer
    private final class Log: Sendable {
        let lines = Mutex<[String]>([])
    }

    private let log = Log()

    /// Query strings of every request received (`t=tvsearch&season=1…`), for tests.
    var requests: [String] { log.lines.withLock { $0 } }

    init(apiKey: String, tvdbID: Int, movieTMDBID: Int, releases: @escaping @Sendable () -> [DemoRelease]) {
        let log = self.log
        server = LoopbackHTTPServer { request in
            let summary = request.query.filter { $0.key != "apikey" }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            log.lines.withLock { $0.append(summary) }
            guard request.path.hasSuffix("/api") else { return .xml("<error code=\"900\" description=\"Not found\"/>", status: 404) }
            guard request.query["apikey"] == apiKey else {
                return .xml("<error code=\"100\" description=\"Incorrect user credentials\"/>")
            }
            switch request.query["t"] ?? "" {
            case "caps":
                return .xml(Self.capsXML)
            case "search", "tvsearch", "movie":
                let items = Self.filter(releases(), query: request.query, tvdbID: tvdbID, movieTMDBID: movieTMDBID)
                return .xml(Self.feed(items))
            default:
                return .xml("<error code=\"202\" description=\"No such function\"/>")
            }
        }
    }

    func start() async throws -> UInt16 { try await server.start() }
    func stop() { server.stop() }

    // MARK: Search

    static func filter(_ all: [DemoRelease], query: [String: String], tvdbID: Int, movieTMDBID: Int) -> [DemoRelease] {
        let function = query["t"] ?? "search"
        var items = all
        switch function {
        case "tvsearch": items = items.filter { $0.kind == .tv }
        case "movie": items = items.filter { $0.kind == .movie }
        default: break
        }
        if let id = query["tvdbid"].flatMap(Int.init), id != tvdbID { return [] }
        if let id = query["tmdbid"].flatMap(Int.init), id != movieTMDBID { return [] }

        var season = query["season"].flatMap(Int.init)
        var episode = query["ep"].flatMap(Int.init)
        if let q = query["q"]?.lowercased(), !q.isEmpty {
            // A text query names the title and may carry an S01E02 / S01 suffix.
            let known = [seriesName, movieName]
            guard known.contains(where: { q.contains($0) }) else { return [] }
            items = items.filter { q.contains($0.kind == .tv ? seriesName : movieName) }
            if let match = q.range(of: #"s(\d+)e(\d+)"#, options: .regularExpression) {
                let digits = q[match].dropFirst().split(separator: "e").compactMap { Int($0) }
                if digits.count == 2 { season = season ?? digits[0]; episode = episode ?? digits[1] }
            } else if let match = q.range(of: #"\bs(\d+)\b"#, options: .regularExpression) {
                season = season ?? Int(q[match].dropFirst())
            }
        }
        if let season { items = items.filter { $0.kind == .tv && $0.season == season } }
        if let episode { items = items.filter { $0.episode == episode } }
        return items
    }

    // MARK: XML

    static let capsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <caps>
          <server title="Marquee demo indexer"/>
          <limits max="100" default="50"/>
          <searching>
            <search available="yes" supportedParams="q"/>
            <tv-search available="yes" supportedParams="q,season,ep,tvdbid"/>
            <movie-search available="yes" supportedParams="q,tmdbid,year"/>
          </searching>
          <categories>
            <category id="2000" name="Movies"><subcat id="2040" name="Movies/HD"/></category>
            <category id="5000" name="TV"><subcat id="5040" name="TV/HD"/></category>
          </categories>
        </caps>
        """

    static func feed(_ items: [DemoRelease]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date())
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
              <channel>
                <title>Marquee demo indexer</title>
                <torznab:response offset="0" total="\(items.count)"/>

            """
        for item in items {
            let category = item.kind == .tv ? 5040 : 2040
            xml += """
                    <item>
                      <title>\(escape(item.title))</title>
                      <guid>\(escape(item.guid))</guid>
                      <pubDate>\(date)</pubDate>
                      <size>\(item.size)</size>
                      <link>\(escape(item.magnet))</link>
                      <enclosure url="\(escape(item.magnet))" length="\(item.size)" type="application/x-bittorrent"/>
                      <torznab:attr name="category" value="\(category)"/>
                      <torznab:attr name="seeders" value="\(item.seeders)"/>
                      <torznab:attr name="peers" value="\(item.seeders + 2)"/>
                      <torznab:attr name="infohash" value="\(item.infoHash)"/>
                    </item>

                """
        }
        xml += "  </channel>\n</rss>\n"
        return xml
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
