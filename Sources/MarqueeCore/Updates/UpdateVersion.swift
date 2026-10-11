import Foundation

/// A dotted version compared **numerically per component**. A lexicographic compare is the classic
/// bug here: it ranks `0.1.9` above `0.1.28`, and the project's tags are `0.1.<github run_number>`,
/// so that exact comparison would pin users on an old build forever.
///
/// A trailing `-suffix` (e.g. `0.2.0-beta.3`) sorts *below* the same version without it, per semver.
public struct UpdateVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Numeric components, most significant first. Never shorter than one.
    public let components: [Int]
    /// The part after the first `-`, if any.
    public let prerelease: String?
    /// The exact string this was parsed from.
    public let description: String

    public init(_ text: String) {
        description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = description
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        if let dash = body.firstIndex(of: "-") {
            prerelease = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
        } else {
            prerelease = nil
        }
        // A junk component (`0.x.3`) becomes 0 rather than failing the parse: a release we cannot
        // order correctly should read as older than anything well-formed, not abort the check.
        components = body.split(separator: ".", omittingEmptySubsequences: true)
            .map { Int($0) ?? 0 }
            .nonEmptyArray ?? [0]
    }

    public init(components: [Int], prerelease: String? = nil) {
        let parts = components.isEmpty ? [0] : components
        self.components = parts
        self.prerelease = prerelease
        description = parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static let zero = UpdateVersion("0")

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        // Same numbers: a prerelease is older than the finished release.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let l?, let r?): return UpdateVersion.isPrereleaseOrderedBefore(l, r)
        }
    }

    /// Compares dot-separated prerelease identifiers the way semver does: numeric identifiers as
    /// numbers, and numeric ones ranking below alphanumeric ones. Comparing the suffix as plain text
    /// puts `beta.10` *before* `beta.9` — the same lexicographic trap the numeric components avoid.
    private static func isPrereleaseOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for (l, r) in zip(left, right) {
            switch (Int(l), Int(r)) {
            case (let l?, let r?):
                if l != r { return l < r }
            case (_?, nil):
                // 1.0.0-1 sorts below 1.0.0-alpha: numeric identifiers have lower precedence.
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if l != r { return l < r }
            }
        }
        // Everything matched; the longer identifier list wins.
        return left.count < right.count
    }
}

extension [Int] {
    fileprivate var nonEmptyArray: [Int]? { isEmpty ? nil : self }
}