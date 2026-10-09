import Foundation

/// Parses Prowlarr's `/api/v1/search` JSON responses into the common release model.
public enum ProwlarrResultParser {
    public static func parse(_ data: Data, indexerID: UUID) throws -> [IndexerRelease] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            if looksLikeHTML(data) {
                throw IndexerError.malformedResponse(
                    "Prowlarr returned an HTML page instead of JSON. Check the URL base, reverse proxy, or access challenge.")
            }
            throw IndexerError.malformedResponse("Prowlarr returned invalid JSON.")
        }
        guard let items = object as? [[String: Any]] else {
            if let error = object as? [String: Any], let message = error["message"] as? String {
                throw IndexerError.apiError(code: 900, description: SecretRedactor.redact(message))
            }
            throw IndexerError.malformedResponse("Prowlarr returned an unexpected search response.")
        }
        return items.compactMap { makeRelease($0, indexerID: indexerID) }
    }

    private static func makeRelease(_ item: [String: Any], indexerID: UUID) -> IndexerRelease? {
        func string(_ key: String) -> String? {
            guard let value = item[key], !(value is NSNull) else { return nil }
            return String(describing: value)
        }
        func integer(_ key: String) -> Int? {
            guard let value = item[key], !(value is NSNull) else { return nil }
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(text) }
            return nil
        }
        func url(_ key: String) -> URL? {
            guard let value = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme), url.host != nil
            else { return nil }
            return url
        }
        func magnet(_ key: String) -> URL? {
            guard let value = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                value.lowercased().hasPrefix("magnet:")
            else { return nil }
            return URL(string: value)
        }

        let protocolName = string("protocol")?.lowercased()
        guard protocolName != "usenet", protocolName != "2" else { return nil }

        let title = string("title")?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") ?? ""
        guard !title.isEmpty else { return nil }

        let magnetURL = magnet("magnetUrl")
        let downloadURL = url("downloadUrl")
        guard let chosenURL = magnetURL ?? downloadURL else { return nil }

        let flags = (item["indexerFlags"] as? [String] ?? []).compactMap { raw -> String? in
            let value = raw.replacingOccurrences(of: "G_", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let normalizedFlags = flags.map { $0.lowercased() }
        let volumeFactor: Double? = normalizedFlags.contains("freeleech") ? 0
            : normalizedFlags.contains(where: { $0.contains("half") }) ? 0.5 : nil
        let size = integer("size").map(Int64.init)
        let publishDate = string("publishDate").flatMap(parseDate)
        let infoURL = url("infoUrl") ?? url("commentUrl") ?? url("guid")
        let guid = string("guid")?.nonEmpty ?? chosenURL.absoluteString
        let seeders = integer("seeders")
        let leechers = integer("leechers")

        return IndexerRelease(
            indexerID: indexerID,
            indexerName: string("indexer")?.nonEmpty ?? "Prowlarr",
            title: title,
            guid: guid,
            downloadURL: downloadURL,
            magnetURL: magnetURL,
            infoHash: magnetURL.flatMap { InfoHash.fromMagnet($0.absoluteString) },
            infoURL: infoURL,
            size: size,
            seeders: seeders,
            peers: seeders.flatMap { seeds in leechers.map { seeds + $0 } },
            leechers: leechers,
            publishDate: publishDate,
            downloadVolumeFactor: volumeFactor,
            indexerFlags: flags)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<html") || head.contains("<!doctype html")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Constructs Prowlarr API URLs while retaining an optional reverse-proxy path prefix.
enum ProwlarrAPIEndpoint {
    static func url(server: URL, endpoint: String, query: [URLQueryItem] = []) throws -> URL {
        guard let scheme = server.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = server.host, !host.isEmpty,
            var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
            components.query == nil, components.fragment == nil,
            components.user == nil, components.password == nil
        else {
            throw IndexerError.invalidConfiguration("Enter a Prowlarr HTTP or HTTPS address without embedded credentials, a query, or a fragment.")
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + "/api/v1/" + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw IndexerError.invalidConfiguration("The Prowlarr address couldn't form a valid API URL.")
        }
        return url
    }
}
