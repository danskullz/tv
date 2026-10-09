import Foundation
import MarqueeCore

/// A keyless, network-free TMDB catalogue for repeatable visual checks (`-tmdbFixtures YES`).
struct FixtureMetadataTransport: MetadataTransport {
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let path = request.url?.pathComponents.filter { $0 != "/" } ?? []
        let fixture: String
        if path.last == "configuration" { fixture = "configuration" }
        else if path.contains("trending") { fixture = "trending_all" }
        else if path.contains("search") { fixture = "search_multi" }
        else if path.contains("discover") || path.contains("popular") {
            fixture = path.contains("tv") ? "discover_tv" : "discover_movie"
        }
        else if path.contains("genres") { fixture = "genres_movie" }
        else if path.contains("providers") { fixture = "providers" }
        else if path.contains("combined_credits") { fixture = "person_credits" }
        else if path.contains("person") { fixture = "person_details" }
        else if path.contains("collection") { fixture = "collection" }
        else if path.contains("season") { fixture = "season_details" }
        else if path.contains("tv") { fixture = "tv_details" }
        else if path.contains("movie") { fixture = "movie_details" }
        else { fixture = "trending_all" }

        guard let url = Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Resources/TMDB"),
              let data = try? Data(contentsOf: url) else {
            return MetadataHTTPResponse(status: 404, body: Data(#"{"status_message":"Fixture not found"}"#.utf8))
        }
        let noArtwork = Self.removingArtworkPaths(data)
        let body = path.contains("search") ? Self.matchingSearchResults(noArtwork, query: Self.queryValue("query", in: request)) : noArtwork
        return MetadataHTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }

    private static func removingArtworkPaths(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) else { return data }
        let keys: Set<String> = ["poster_path", "backdrop_path", "profile_path", "still_path", "logo_path"]
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(strip).merging(
                    Dictionary(uniqueKeysWithValues: keys.filter { dictionary[$0] != nil }.map { ($0, NSNull() as Any) })
                ) { _, replacement in replacement }
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        object = strip(object)
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private static func matchingSearchResults(_ data: Data, query: String?) -> Data {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !query.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return data }
        let matches = results.filter { result in
            ["title", "name", "original_title", "original_name"].compactMap { result[$0] as? String }
                .contains { $0.localizedStandardContains(query) }
        }
        object["results"] = matches
        object["total_results"] = matches.count
        object["total_pages"] = 1
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
