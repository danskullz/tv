import Foundation

/// Small, deterministic operations shared by catalogue screens and tested without TMDB or the UI.
public enum BrowseDataShaping {
    /// Keeps the first value for an ID, preserving shelf/search order.
    public static func unique<Item: Identifiable, ID: Hashable>(
        _ items: [Item], limit: Int = .max, id: (Item) -> ID
    ) -> [Item] {
        var seen = Set<ID>()
        var result: [Item] = []
        result.reserveCapacity(min(items.count, limit))
        for item in items where seen.insert(id(item)).inserted {
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }

    /// Merges local-first and catalogue hits into one stable, fuzzy-ranked list.
    public static func mergeSearch<Item, ID: Hashable>(
        library: [Item], catalogue: [Item], query: String,
        id: (Item) -> ID, title: (Item) -> String
    ) -> [Item] {
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [(item: Item, score: Int, ordinal: Int)] = []
        var seen = Set<ID>()
        for (ordinal, item) in (library.map { ($0, true) } + catalogue.map { ($0, false) }).enumerated() {
            guard seen.insert(id(item.0)).inserted else { continue }
            values.append((item.0, relevance(title(item.0), query: q) + (item.1 ? 4 : 0), ordinal))
        }
        return values.sorted { $0.score == $1.score ? $0.ordinal < $1.ordinal : $0.score > $1.score }.map(\.item)
    }

    private static func relevance(_ title: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let value = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if value == query { return 100 }
        if value.hasPrefix(query) { return 80 }
        if value.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(query) }) { return 65 }
        if value.contains(query) { return 45 }
        var cursor = value.startIndex
        var matched = 0
        for character in query {
            guard let found = value[cursor...].firstIndex(of: character) else { return 0 }
            matched += 1
            cursor = value.index(after: found)
        }
        return matched == query.count ? 15 : 0
    }
}
