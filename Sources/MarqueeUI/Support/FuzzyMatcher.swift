import Foundation

/// Pre-folded index for instant fuzzy filtering (command palette, search). Build once, query per keystroke.
public struct FuzzyIndex<Element: Sendable>: Sendable {
    private struct Entry: Sendable {
        let element: Element
        let folded: [Character]
        let wordStarts: [Bool]
        let order: Int
    }

    private let entries: [Entry]

    public init(_ elements: [Element], key: (Element) -> String) {
        entries = elements.enumerated().map { index, element in
            let folded = Array(Self.fold(key(element)))
            var starts = [Bool](repeating: false, count: folded.count)
            var previousIsLetter = false
            for (i, ch) in folded.enumerated() {
                let isLetter = ch.isLetter || ch.isNumber
                starts[i] = isLetter && !previousIsLetter
                previousIsLetter = isLetter
            }
            return Entry(element: element, folded: folded, wordStarts: starts, order: index)
        }
    }

    /// Elements matching `query` (all query characters appear in order), best first.
    /// An empty query returns the first `limit` elements in their original order.
    public func search(_ query: String, limit: Int = 50) -> [Element] {
        let q = Array(Self.fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return entries.prefix(limit).map(\.element) }
        var scored: [(score: Int, order: Int, element: Element)] = []
        for entry in entries {
            if let s = Self.score(q, in: entry.folded, wordStarts: entry.wordStarts) {
                scored.append((s, entry.order, entry.element))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.element)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Subsequence score: consecutive runs and word-start hits score higher, gaps cost a little.
    private static func score(_ q: [Character], in c: [Character], wordStarts: [Bool]) -> Int? {
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch = -1
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 10
            if ci == lastMatch + 1 { score += 14 }
            if wordStarts[ci] { score += 18 }
            if firstMatch < 0 { firstMatch = ci }
            else if ci > lastMatch + 1 { score -= min(6, ci - lastMatch - 1) }
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if firstMatch == 0 { score += 24 }
        if c.count == q.count { score += 40 }
        return score - min(10, c.count / 8)
    }
}
