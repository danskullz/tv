import Foundation

/// A Torznab search function. `capsElement` is the name under `<searching>` in `t=caps`;
/// `tParameter` is the value of the `t=` query parameter.
public enum TorznabSearchFunction: String, Sendable, Hashable, Codable, CaseIterable {
    case search
    case tvSearch
    case movieSearch

    public var capsElement: String {
        switch self {
        case .search: "search"
        case .tvSearch: "tv-search"
        case .movieSearch: "movie-search"
        }
    }

    public var tParameter: String {
        switch self {
        case .search: "search"
        case .tvSearch: "tvsearch"
        case .movieSearch: "movie"
        }
    }
}

public struct TorznabCategory: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var subcategories: [TorznabCategory]

    public init(id: Int, name: String, subcategories: [TorznabCategory] = []) {
        self.id = id
        self.name = name
        self.subcategories = subcategories
    }
}

public struct TorznabSearchMode: Sendable, Hashable, Codable {
    public var available: Bool
    /// Lowercased parameter names, e.g. `q`, `season`, `ep`, `imdbid`, `tvdbid`, `tmdbid`.
    public var supportedParams: Set<String>

    public init(available: Bool, supportedParams: Set<String>) {
        self.available = available
        self.supportedParams = supportedParams
    }
}

public struct TorznabLimits: Sendable, Hashable, Codable {
    public var max: Int?
    public var `default`: Int?

    public init(max: Int? = nil, default: Int? = nil) {
        self.max = max
        self.default = `default`
    }
}

/// Parsed `t=caps` response.
public struct TorznabCapabilities: Sendable, Hashable, Codable {
    public var serverTitle: String?
    public var limits: TorznabLimits
    /// Keyed by the `<searching>` child element name (`search`, `tv-search`, `movie-search`, `music-search`, ...).
    public var searchModes: [String: TorznabSearchMode]
    public var categories: [TorznabCategory]

    public init(
        serverTitle: String? = nil,
        limits: TorznabLimits = TorznabLimits(),
        searchModes: [String: TorznabSearchMode] = [:],
        categories: [TorznabCategory] = []
    ) {
        self.serverTitle = serverTitle
        self.limits = limits
        self.searchModes = searchModes
        self.categories = categories
    }

    public func supports(_ function: TorznabSearchFunction) -> Bool {
        searchModes[function.capsElement]?.available ?? false
    }

    public func supports(_ function: TorznabSearchFunction, param: String) -> Bool {
        guard let mode = searchModes[function.capsElement], mode.available else { return false }
        return mode.supportedParams.contains(param.lowercased())
    }

    /// Every category, parents and children, in document order.
    public var flattenedCategories: [TorznabCategory] {
        func walk(_ nodes: [TorznabCategory]) -> [TorznabCategory] {
            nodes.flatMap { [$0] + walk($0.subcategories) }
        }
        return walk(categories)
    }

    public func containsCategory(_ id: Int) -> Bool {
        flattenedCategories.contains { $0.id == id }
    }

    public static func parse(_ data: Data) throws -> TorznabCapabilities {
        try TorznabCapsParser.parse(data)
    }
}

enum TorznabCapsParser {
    static func parse(_ data: Data) throws -> TorznabCapabilities {
        try TorznabXMLPreflight.check(data)
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let (code, description) = delegate.apiError {
            throw IndexerError.fromAPIError(code: code, description: description)
        }
        guard ok else {
            throw IndexerError.malformedResponse("The capabilities document is not valid XML: \(parser.parserError?.localizedDescription ?? "unknown error").")
        }
        guard delegate.rootName == "caps" else {
            throw IndexerError.malformedResponse("Expected a Torznab capabilities document but received <\(delegate.rootName ?? "nothing")>.")
        }
        var modes = delegate.modes
        if modes.isEmpty {
            // Very old or minimal servers omit <searching>; plain text search is the baseline.
            modes["search"] = TorznabSearchMode(available: true, supportedParams: ["q"])
        }
        return TorznabCapabilities(
            serverTitle: delegate.serverTitle,
            limits: delegate.limits,
            searchModes: modes,
            categories: delegate.categories)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Node {
            var id: Int?
            var name: String
            var children: [TorznabCategory] = []
        }

        var rootName: String?
        var apiError: (Int, String)?
        var serverTitle: String?
        var limits = TorznabLimits()
        var modes: [String: TorznabSearchMode] = [:]
        var categories: [TorznabCategory] = []
        private var stack: [Node] = []
        private var inSearching = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            let name = TorznabXMLNames.local(elementName)
            if rootName == nil {
                rootName = name
                if name == "error" {
                    apiError = (Int(attributeDict["code"] ?? "") ?? 900, attributeDict["description"] ?? "")
                    parser.abortParsing()
                    return
                }
            }
            switch name {
            case "server":
                serverTitle = attributeDict["title"]
            case "limits":
                limits = TorznabLimits(
                    max: Int(attributeDict["max"] ?? ""), default: Int(attributeDict["default"] ?? ""))
            case "searching":
                inSearching = true
            case "category", "subcat":
                stack.append(Node(id: Int(attributeDict["id"] ?? ""), name: attributeDict["name"] ?? ""))
            default:
                if inSearching {
                    let available = TorznabXMLNames.isTruthy(attributeDict["available"], default: true)
                    let params = (attributeDict["supportedParams"] ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                    modes[name] = TorznabSearchMode(available: available, supportedParams: Set(params))
                }
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            switch TorznabXMLNames.local(elementName) {
            case "searching":
                inSearching = false
            case "category", "subcat":
                guard let node = stack.popLast() else { return }
                guard let id = node.id else { return }
                let category = TorznabCategory(id: id, name: node.name, subcategories: node.children)
                if stack.isEmpty {
                    categories.append(category)
                } else {
                    stack[stack.count - 1].children.append(category)
                }
            default:
                break
            }
        }
    }
}

enum TorznabXMLNames {
    /// Strips a namespace prefix (`torznab:attr` -> `attr`) and lowercases.
    static func local(_ name: String) -> String {
        let stripped = name.split(separator: ":").last.map(String.init) ?? name
        return stripped.lowercased()
    }

    static func isTruthy(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        switch value.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return fallback
        }
    }
}

enum TorznabXMLPreflight {
    /// Rejects empty bodies and HTML pages (login / bot-challenge pages) with a clear message
    /// before the XML parser produces a confusing one.
    static func check(_ data: Data) throws {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !head.isEmpty else {
            throw IndexerError.malformedResponse("The indexer returned an empty response.")
        }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.contains("<html") && !head.contains("<rss") {
            throw IndexerError.malformedResponse("The indexer returned a web page instead of Torznab XML (a login or bot-protection page?).")
        }
    }
}
