import Foundation

enum BuiltInProviderSearch {
    static func url(provider: BuiltInProvider, server: URL, query: TorznabQuery) throws -> URL {
        guard let scheme = server.scheme?.lowercased(), ["http", "https"].contains(scheme),
            server.host != nil,
            var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
            components.query == nil, components.fragment == nil
        else {
            throw IndexerError.invalidConfiguration("This provider needs a valid HTTP or HTTPS address.")
        }

        let text = searchText(query)
        if text.isEmpty && !(provider == .eztv && query.imdbID != nil) {
            throw IndexerError.unsupportedSearch("Enter a title to search this provider.")
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = prefix.isEmpty ? "" : "/" + prefix
        var parameters: [URLQueryItem] = []
        switch provider {
        case .eztv:
            components.percentEncodedPath = root + "/api/get-torrents"
            parameters = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "page", value: "1")]
            if let imdb = query.imdbID, let digits = imdbDigits(imdb) {
                parameters.append(URLQueryItem(name: "imdb_id", value: digits))
            } else {
                parameters.append(URLQueryItem(name: "keywords", value: text))
            }
        case .limeTorrents:
            let category: String
            switch query.kind {
            case .generic: category = "all"
            case .tv: category = "tv"
            case .movie: category = "movies"
            }
            let slug = text.replacingOccurrences(of: " ", with: "-")
            components.percentEncodedPath = root + "/search/\(category)/\(encodePathSegment(slug))/seeds/1/"
        case .solidTorrents:
            components.percentEncodedPath = root + "/api/v1/search"
            parameters = [
                URLQueryItem(name: "q", value: text), URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "limit", value: "100"),
            ]
        case .pirateBay:
            components.percentEncodedPath = root + "/q.php"
            let category: String
            switch query.kind {
            case .generic: category = "0"
            case .tv: category = "205"
            case .movie: category = "200"
            }
            parameters = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "cat", value: category)]
        case .torrentProject:
            components.percentEncodedPath = root + "/"
            parameters = [URLQueryItem(name: "s", value: text), URLQueryItem(name: "out", value: "json")]
        case .torrentsCSV:
            components.percentEncodedPath = root + "/service/search"
            parameters = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "size", value: "100")]
        }
        components.queryItems = parameters
        guard let result = components.url else {
            throw IndexerError.invalidConfiguration("Marquee couldn't build this provider's search address.")
        }
        return result
    }

    static func parse(
        _ data: Data, provider: BuiltInProvider, indexerID: UUID, indexerName: String,
        query: TorznabQuery, server: URL
    ) throws -> [IndexerRelease] {
        if provider == .limeTorrents {
            return try parseLimeTorrents(data, indexerID: indexerID, indexerName: indexerName, baseURL: server)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            if head.contains("<html") || head.contains("<!doctype html") {
                throw IndexerError.malformedResponse("\(indexerName) returned a web page instead of its search data.")
            }
            throw IndexerError.malformedResponse("\(indexerName) returned invalid JSON.")
        }
        let values: [[String: Any]]
        switch provider {
        case .eztv:
            guard let envelope = object as? [String: Any], let rows = envelope["torrents"] as? [[String: Any]] else {
                throw schemaError(provider)
            }
            values = rows
        case .solidTorrents:
            guard let envelope = object as? [String: Any], envelope["success"] as? Bool == true,
                let rows = envelope["results"] as? [[String: Any]]
            else { throw schemaError(provider) }
            values = rows
        case .pirateBay:
            guard let rows = object as? [[String: Any]] else { throw schemaError(provider) }
            values = rows
        case .torrentProject:
            guard let envelope = object as? [String: Any], let rows = envelope["torrents"] as? [[String: Any]] else {
                throw IndexerError.malformedResponse(
                    "TorrentProject's search API returned an unsupported response. The listed endpoint may be obsolete.")
            }
            values = rows
        case .torrentsCSV:
            guard let envelope = object as? [String: Any], let rows = envelope["torrents"] as? [[String: Any]] else {
                throw schemaError(provider)
            }
            values = rows
        case .limeTorrents:
            values = []
        }
        return values.compactMap { map($0, provider: provider, indexerID: indexerID, indexerName: indexerName, server: server) }
    }

    private static func map(
        _ row: [String: Any], provider: BuiltInProvider, indexerID: UUID, indexerName: String, server: URL
    ) -> IndexerRelease? {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = row[key], !(value is NSNull) {
                    let result = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty { return result }
                }
            }
            return nil
        }
        func integer(_ keys: String...) -> Int? {
            for key in keys {
                if let value = row[key], !(value is NSNull) {
                    if let number = value as? NSNumber { return number.intValue }
                    if let text = value as? String, let parsed = Int(text) { return parsed }
                }
            }
            return nil
        }
        let title = (string("title", "name", "filename") ?? "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !title.isEmpty else { return nil }

        let hash = string("infohash", "info_hash", "hash").flatMap(InfoHash.normalize)
        let magnetValue = string("magnet_url", "magnetUrl", "magnet")
        let magnet = magnetValue.flatMap(validMagnet) ?? hash.flatMap { magnetURL(hash: $0, title: title) }
        let download = string("downloadUrl", "download_url", "url").flatMap { webURL($0, relativeTo: server) }
        guard magnet != nil || download != nil else { return nil }

        let size = integer("size_bytes", "size")
        let seeders = integer("seeders", "seeds")
        let peerCount = integer("peers")
        let leechers = integer("leechers", "leech") ?? peerCount.flatMap { peers in
            seeders.map { max(0, peers - $0) }
        }
        let dateValue = integer("date_released_unix", "created_unix", "added", "publishDate")
        let date = dateValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? string("createdAt", "updatedAt", "publishDate", "created").flatMap(parseDate)
        let guid = string("id", "guid") ?? hash ?? magnet?.absoluteString ?? title
        let infoURL = string("infoUrl", "info_url", "detailsUrl")
            .flatMap { webURL($0, relativeTo: server) }

        return IndexerRelease(
            indexerID: indexerID, indexerName: string("indexer") ?? indexerName,
            title: title, guid: guid,
            downloadURL: download, magnetURL: magnet, infoHash: hash ?? magnet.flatMap { InfoHash.fromMagnet($0.absoluteString) },
            infoURL: infoURL, size: size.map(Int64.init), seeders: seeders,
            peers: peerCount ?? seeders.flatMap { seeds in leechers.map { seeds + $0 } }, leechers: leechers,
            publishDate: date)
    }

    private static func parseLimeTorrents(
        _ data: Data, indexerID: UUID, indexerName: String, baseURL: URL
    ) throws -> [IndexerRelease] {
        let html = String(decoding: data, as: UTF8.self)
        let rows = matches(#"(?is)<tr\b[^>]*>.*?</tr\s*>"#, in: html)
        var releases: [IndexerRelease] = []
        for row in rows {
            let anchors = matches(#"(?is)<a\b[^>]*>.*?</a\s*>"#, in: row)
            let links = anchors.compactMap { anchor -> (href: String, text: String)? in
                guard let href = attribute("href", in: anchor) else { return nil }
                return (href, plainText(anchor))
            }
            guard let torrent = links.first(where: { $0.href.lowercased().contains(".torrent") }),
                let details = links.first(where: { $0.href.lowercased().hasSuffix(".html") }),
                !details.text.isEmpty
            else { continue }

            let cells = matches(#"(?is)<td\b[^>]*>.*?</td\s*>"#, in: row).map(plainText)
            let date = cells.count > 1 ? parseRelativeDate(cells[1]) : nil
            let size = cells.count > 2 ? parseSize(cells[2]) : nil
            let seeders = cells.count > 3 ? parseInteger(cells[3]) : nil
            let leechers = cells.count > 4 ? parseInteger(cells[4]) : nil
            let torrentURL = webURL(torrent.href, relativeTo: baseURL)
            guard let torrentURL else { continue }
            releases.append(IndexerRelease(
                indexerID: indexerID, indexerName: indexerName, title: details.text,
                guid: details.href, downloadURL: torrentURL,
                infoURL: webURL(details.href, relativeTo: baseURL), size: size,
                seeders: seeders, peers: seeders.flatMap { seeds in leechers.map { seeds + $0 } },
                leechers: leechers, publishDate: date))
        }
        if releases.isEmpty && !(html.lowercased().contains("search results") || html.lowercased().contains("no torrents")) {
            throw IndexerError.malformedResponse("LimeTorrents didn't return its search results. The site may be blocking Marquee.")
        }
        return releases
    }

    private static func schemaError(_ provider: BuiltInProvider) -> IndexerError {
        .malformedResponse("\(provider.name) returned a response Marquee couldn't read.")
    }

    private static func searchText(_ query: TorznabQuery) -> String {
        var text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.kind == .tv, let season = query.season {
            text += String(format: " S%02d", season)
            if let episode = query.episode { text += String(format: "E%02d", episode) }
        } else if query.kind == .movie, let year = query.year {
            text += " \(year)"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func imdbDigits(_ value: String) -> String? {
        let digits = value.lowercased().hasPrefix("tt") ? String(value.dropFirst(2)) : value
        return digits.allSatisfy(\.isNumber) && !digits.isEmpty ? digits : nil
    }

    private static func encodePathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func magnetURL(hash: String, title: String) -> URL? {
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:\(hash)"), URLQueryItem(name: "dn", value: title)]
        return components.url
    }

    private static func validMagnet(_ raw: String) -> URL? {
        guard raw.lowercased().hasPrefix("magnet:"), let url = URL(string: raw), InfoHash.fromMagnet(raw) != nil else { return nil }
        return url
    }

    private static func webURL(_ raw: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?is)\b\#(NSRegularExpression.escapedPattern(for: name))\s*=\s*(['\"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
            let range = Range(match.range(at: 2), in: tag)
        else { return nil }
        return decodeEntities(String(tag[range]))
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(withoutTags).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        let numeric = matches(#"&#(x?[0-9a-fA-F]+);"#, in: result)
        for entity in numeric {
            let body = String(entity.dropFirst(2).dropLast())
            let isHex = body.hasPrefix("x") || body.hasPrefix("X")
            let digits = isHex ? String(body.dropFirst()) : body
            guard let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = UnicodeScalar(value) else { continue }
            result = result.replacingOccurrences(of: entity, with: String(scalar))
        }
        return result
    }

    private static func parseInteger(_ raw: String) -> Int? {
        Int(raw.filter(\.isNumber))
    }

    private static func parseSize(_ raw: String) -> Int64? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let amount = Double(parts[0].replacingOccurrences(of: ",", with: "")) else { return nil }
        let units = ["b": 1.0, "kb": 1_000.0, "mb": 1_000_000.0, "gb": 1_000_000_000.0,
                     "tb": 1_000_000_000_000.0, "kib": 1_024.0, "mib": 1_048_576.0,
                     "gib": 1_073_741_824.0, "tib": 1_099_511_627_776.0]
        guard let multiplier = units[String(parts[1]).lowercased()] else { return nil }
        return Int64(amount * multiplier)
    }

    private static func parseRelativeDate(_ raw: String, now: Date = Date()) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patterns: [(String, Calendar.Component, Int)] = [
            (#"^(\d+)\s+hours?\s+ago$"#, .hour, 1), (#"^(\d+)\s+days?\s+ago$"#, .day, 1),
            (#"^(\d+)\s+months?\s+ago$"#, .month, 1), (#"^(\d+)\s+years?\s+ago$"#, .year, 1),
        ]
        for (pattern, component, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                let range = Range(match.range(at: 1), in: value), let count = Int(value[range])
            else { continue }
            return Calendar.current.date(byAdding: component, value: -count, to: now)
        }
        if value == "yesterday" { return Calendar.current.date(byAdding: .day, value: -1, to: now) }
        return nil
    }

    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
