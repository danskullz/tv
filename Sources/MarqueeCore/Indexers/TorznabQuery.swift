import Foundation

/// What the caller wants to find. Independent of any particular indexer; `TorznabQueryBuilder`
/// turns it into the best request each indexer's capabilities allow.
public struct TorznabQuery: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case generic
        case tv
        case movie
    }

    public var kind: Kind
    /// Free text: a title for TV/movie searches, anything for generic. `nil` on a generic query asks for the latest releases (RSS-style).
    public var text: String?
    public var season: Int?
    public var episode: Int?
    /// `tt1234567` or bare digits.
    public var imdbID: String?
    public var tvdbID: Int?
    public var tmdbID: Int?
    public var year: Int?
    /// Overrides the indexer's configured categories when set.
    public var categories: [Int]?
    public var limit: Int?
    public var offset: Int?

    public init(
        kind: Kind, text: String? = nil, season: Int? = nil, episode: Int? = nil, imdbID: String? = nil,
        tvdbID: Int? = nil, tmdbID: Int? = nil, year: Int? = nil, categories: [Int]? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) {
        self.kind = kind
        self.text = text
        self.season = season
        self.episode = episode
        self.imdbID = imdbID
        self.tvdbID = tvdbID
        self.tmdbID = tmdbID
        self.year = year
        self.categories = categories
        self.limit = limit
        self.offset = offset
    }

    public static func generic(_ text: String? = nil, categories: [Int]? = nil, limit: Int? = nil, offset: Int? = nil) -> TorznabQuery {
        TorznabQuery(kind: .generic, text: text, categories: categories, limit: limit, offset: offset)
    }

    public static func tv(
        title: String? = nil, season: Int? = nil, episode: Int? = nil, imdbID: String? = nil,
        tvdbID: Int? = nil, tmdbID: Int? = nil, categories: [Int]? = nil, limit: Int? = nil
    ) -> TorznabQuery {
        TorznabQuery(
            kind: .tv, text: title, season: season, episode: episode, imdbID: imdbID, tvdbID: tvdbID,
            tmdbID: tmdbID, categories: categories, limit: limit)
    }

    public static func movie(
        title: String? = nil, year: Int? = nil, imdbID: String? = nil, tmdbID: Int? = nil,
        categories: [Int]? = nil, limit: Int? = nil
    ) -> TorznabQuery {
        TorznabQuery(
            kind: .movie, text: title, imdbID: imdbID, tmdbID: tmdbID, year: year, categories: categories, limit: limit)
    }
}

public struct TorznabParameter: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// The concrete request chosen for one indexer. Excludes `t` and `apikey`, which are added when the URL is built.
public struct TorznabRequestPlan: Sendable, Equatable {
    public var function: TorznabSearchFunction
    public var parameters: [TorznabParameter]
    /// True when the indexer lacks the requested search type (or id parameters) and plain text search was used instead.
    public var usedTextFallback: Bool

    public func value(_ name: String) -> String? {
        parameters.first { $0.name == name }?.value
    }
}

public enum TorznabQueryBuilder {
    /// Chooses function and parameters for `query` given what the indexer says it supports.
    ///
    /// Id parameters are preferred (precise); when the indexer doesn't support any id the query carries,
    /// the title is used as text (with `S01E02` appended if season/episode aren't supported natively).
    /// When ids are used, `q` is omitted because some indexers AND the two and return nothing.
    public static func plan(
        for query: TorznabQuery, definition: IndexerDefinition, capabilities caps: TorznabCapabilities,
        defaultLimit: Int = 100
    ) throws -> TorznabRequestPlan {
        let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var params: [TorznabParameter] = []
        var function = TorznabSearchFunction.search
        var fallback = false

        switch query.kind {
        case .generic:
            guard caps.supports(.search) else {
                throw IndexerError.unsupportedSearch("It doesn't offer plain text search.")
            }
            if let text { params.append(TorznabParameter("q", text)) }

        case .tv:
            if caps.supports(.tvSearch) {
                function = .tvSearch
                var idUsed = false
                if let imdb = query.imdbID.flatMap(imdbDigits), caps.supports(.tvSearch, param: "imdbid") {
                    params.append(TorznabParameter("imdbid", imdb)); idUsed = true
                }
                if let tvdb = query.tvdbID, caps.supports(.tvSearch, param: "tvdbid") {
                    params.append(TorznabParameter("tvdbid", String(tvdb))); idUsed = true
                }
                if let tmdb = query.tmdbID, caps.supports(.tvSearch, param: "tmdbid") {
                    params.append(TorznabParameter("tmdbid", String(tmdb))); idUsed = true
                }
                var suffix: [String] = []
                if let season = query.season {
                    if caps.supports(.tvSearch, param: "season") {
                        params.append(TorznabParameter("season", String(season)))
                    } else {
                        suffix.append(String(format: "S%02d", season))
                    }
                    if let episode = query.episode {
                        if caps.supports(.tvSearch, param: "ep") {
                            params.append(TorznabParameter("ep", String(episode)))
                        } else if let last = suffix.popLast() {
                            suffix.append(last + String(format: "E%02d", episode))
                        }
                    }
                }
                if !idUsed {
                    guard let text, caps.supports(.tvSearch, param: "q") else {
                        throw IndexerError.unsupportedSearch("It can't look up shows by that ID and no title was given to search for.")
                    }
                    fallback = hasIDs(query)
                    params.insert(TorznabParameter("q", ([text] + suffix).joined(separator: " ")), at: 0)
                }
            } else if caps.supports(.search) {
                function = .search
                fallback = true
                guard let text else {
                    throw IndexerError.unsupportedSearch("It doesn't support TV searches by ID and no title was given.")
                }
                var suffix = ""
                if let season = query.season {
                    suffix = String(format: " S%02d", season)
                    if let episode = query.episode { suffix += String(format: "E%02d", episode) }
                }
                params.append(TorznabParameter("q", text + suffix))
            } else {
                throw IndexerError.unsupportedSearch("It doesn't offer TV search.")
            }

        case .movie:
            if caps.supports(.movieSearch) {
                function = .movieSearch
                var idUsed = false
                if let imdb = query.imdbID.flatMap(imdbDigits), caps.supports(.movieSearch, param: "imdbid") {
                    params.append(TorznabParameter("imdbid", imdb)); idUsed = true
                }
                if let tmdb = query.tmdbID, caps.supports(.movieSearch, param: "tmdbid") {
                    params.append(TorznabParameter("tmdbid", String(tmdb))); idUsed = true
                }
                if !idUsed {
                    guard let text, caps.supports(.movieSearch, param: "q") else {
                        throw IndexerError.unsupportedSearch("It can't look up movies by that ID and no title was given to search for.")
                    }
                    fallback = hasIDs(query)
                    var q = text
                    if let year = query.year {
                        if caps.supports(.movieSearch, param: "year") {
                            params.append(TorznabParameter("year", String(year)))
                        } else {
                            q += " \(year)"
                        }
                    }
                    params.insert(TorznabParameter("q", q), at: 0)
                } else if let year = query.year, caps.supports(.movieSearch, param: "year") {
                    params.append(TorznabParameter("year", String(year)))
                }
            } else if caps.supports(.search) {
                function = .search
                fallback = true
                guard let text else {
                    throw IndexerError.unsupportedSearch("It doesn't support movie searches by ID and no title was given.")
                }
                params.append(TorznabParameter("q", query.year.map { "\(text) \($0)" } ?? text))
            } else {
                throw IndexerError.unsupportedSearch("It doesn't offer movie search.")
            }
        }

        let cats = categories(for: query, definition: definition, capabilities: caps)
        if !cats.isEmpty { params.append(TorznabParameter("cat", cats.map(String.init).joined(separator: ","))) }
        params.append(TorznabParameter("extended", "1"))

        var limit = query.limit ?? caps.limits.default ?? defaultLimit
        if let max = caps.limits.max { limit = min(limit, max) }
        params.append(TorznabParameter("limit", String(max(1, limit))))
        if let offset = query.offset, offset > 0 { params.append(TorznabParameter("offset", String(offset))) }

        return TorznabRequestPlan(function: function, parameters: params, usedTextFallback: fallback)
    }

    /// Query override > indexer categories relevant to the search type > standard TV/Movie top-level category.
    static func categories(for query: TorznabQuery, definition: IndexerDefinition, capabilities caps: TorznabCapabilities) -> [Int] {
        if let explicit = query.categories, !explicit.isEmpty { return explicit }
        let range: ClosedRange<Int>
        let fallbackCategory: Int
        switch query.kind {
        case .generic: return definition.categories
        case .tv: range = 5000...5999; fallbackCategory = 5000
        case .movie: range = 2000...2999; fallbackCategory = 2000
        }
        let configured = definition.categories.filter { range.contains($0) }
        if !configured.isEmpty { return configured }
        // Only send the default if the indexer actually has that category (or didn't list any).
        return caps.categories.isEmpty || caps.containsCategory(fallbackCategory) ? [fallbackCategory] : []
    }

    private static func hasIDs(_ q: TorznabQuery) -> Bool {
        q.imdbID != nil || q.tvdbID != nil || q.tmdbID != nil
    }

    /// `tt0903747` -> `0903747` (the *arr convention; Jackett and Prowlarr accept both forms).
    static func imdbDigits(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("tt") { s.removeFirst(2) }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return s
    }
}

/// Builds the final request URL. All values are percent-encoded with the RFC 3986 unreserved set so
/// titles like `Law & Order` or `C++` survive intact.
public enum TorznabEndpoint {
    public static func url(
        definition: IndexerDefinition, function tValue: String, parameters: [TorznabParameter], apiKey: String?
    ) throws -> URL {
        guard let scheme = definition.baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = definition.baseURL.host, !host.isEmpty
        else {
            throw IndexerError.invalidConfiguration("The address must start with http:// or https://.")
        }
        guard var components = URLComponents(url: definition.baseURL, resolvingAgainstBaseURL: false) else {
            throw IndexerError.invalidConfiguration("The address isn't a valid URL.")
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        var api = definition.apiPath.trimmingCharacters(in: .whitespaces)
        while api.hasPrefix("/") { api.removeFirst() }
        components.percentEncodedPath = prefix + "/" + api
        components.fragment = nil

        var items = [TorznabParameter("t", tValue)]
        if let apiKey, !apiKey.isEmpty { items.append(TorznabParameter("apikey", apiKey)) }
        items += parameters
        components.percentEncodedQuery = items.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")

        guard let url = components.url else {
            throw IndexerError.invalidConfiguration("The address and API path don't form a valid URL.")
        }
        return url
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

fileprivate extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
