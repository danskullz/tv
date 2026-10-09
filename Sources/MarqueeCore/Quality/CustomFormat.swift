import Foundation
import Synchronization

/// What a ``FormatSpecification`` inspects.
public enum SpecificationType: String, Sendable, Hashable, Codable, CaseIterable {
    /// Regular expression against the whole release name (case-insensitive).
    case releaseTitle
    /// Release group name; `value` is matched against the whole group name (alternatives via `|`).
    case releaseGroup
    case source, resolution, videoCodec, hdr, audioCodec, audioChannels, language, edition
    case streamingService
    /// Indexer-reported flags: `freeleech`, `halfleech`, `doubleupload`.
    case indexerFlag
    /// A ``ReleaseFlag`` raw value such as `proper`, `repack`, `hardcodedSubs`, `threeD`.
    case releaseFlag
    /// Release size, `min`/`max` in GiB.
    case size
}

/// One rule of a custom format. See ``CustomFormatConfig`` for matching semantics and the JSON schema.
public struct FormatSpecification: Sendable, Hashable, Codable {
    public var name: String
    public var type: SpecificationType
    /// Regex for `releaseTitle`/`releaseGroup`; otherwise a case/punctuation-insensitive name
    /// ("WEB-DL", "dts-hd ma", "HDR10+", "x265", "5.1", "4K").
    public var value: String
    /// Inclusive lower bound in GiB (`size` only).
    public var min: Double?
    /// Inclusive upper bound in GiB (`size` only).
    public var max: Double?
    /// Inverts the result of this specification.
    public var negate: Bool
    /// Must pass (after `negate`) for the format to match.
    public var required: Bool

    public init(
        name: String = "", type: SpecificationType, value: String = "", min: Double? = nil, max: Double? = nil,
        negate: Bool = false, required: Bool = false
    ) {
        self.name = name.isEmpty ? "\(type.rawValue): \(value)" : name
        self.type = type
        self.value = value
        self.min = min
        self.max = max
        self.negate = negate
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case name, type, value, min, max, negate, required }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(SpecificationType.self, forKey: .type)
        self.init(
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            type: type,
            value: try c.decodeIfPresent(String.self, forKey: .value) ?? "",
            min: try c.decodeIfPresent(Double.self, forKey: .min),
            max: try c.decodeIfPresent(Double.self, forKey: .max),
            negate: try c.decodeIfPresent(Bool.self, forKey: .negate) ?? false,
            required: try c.decodeIfPresent(Bool.self, forKey: .required) ?? false)
    }
}

/// A named bundle of specifications that, when it matches a release, contributes a per-profile score.
///
/// **Matching semantics** (same idea as Sonarr/Radarr custom formats, independently implemented):
/// - A specification's result is `rawMatch != negate`.
/// - Every `required` specification must pass.
/// - For each ``SpecificationType`` that has at least one non-required specification, at least one
///   non-required specification of that type must pass.
/// - A format with no specifications never matches.
///
/// **JSON schema** (see ``FormatBundle`` for whole bundles):
/// ```json
/// { "id": "uuid (optional on import)", "name": "HDR10+",
///   "specifications": [
///     { "name": "HDR10+", "type": "hdr", "value": "hdr10+", "negate": false, "required": false },
///     { "name": "Not a sample", "type": "releaseFlag", "value": "sample", "negate": true, "required": true } ] }
/// ```
public struct CustomFormatConfig: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var specifications: [FormatSpecification]

    public init(id: UUID = UUID(), name: String, specifications: [FormatSpecification]) {
        self.id = id
        self.name = name
        self.specifications = specifications
    }

    private enum CodingKeys: String, CodingKey { case id, name, specifications }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decode(String.self, forKey: .name),
            specifications: try c.decodeIfPresent([FormatSpecification].self, forKey: .specifications) ?? [])
    }

    /// Whether this format matches a candidate. Compiles regexes through a shared cache, so repeated
    /// calls are cheap; the decision engine precompiles once per run.
    public func matches(_ candidate: ReleaseCandidate) -> Bool {
        CompiledFormat(self).matches(CandidateFacts(candidate))
    }

    /// Specifications that can never match as written (e.g. an invalid regex).
    public var validationIssues: [String] {
        specifications.compactMap { spec in
            switch spec.type {
            case .releaseTitle, .releaseGroup:
                PatternMatcher.make(spec.value, wholeString: spec.type == .releaseGroup).isValid
                    ? nil : "Invalid pattern in \"\(spec.name)\""
            case .size:
                (spec.min == nil && spec.max == nil) ? "Size specification \"\(spec.name)\" has no bounds" : nil
            default:
                spec.value.isEmpty ? "Specification \"\(spec.name)\" has no value" : nil
            }
        }
    }
}

/// A scored match, reported on decisions and in explanations.
public struct FormatMatch: Sendable, Hashable, Codable {
    public var formatID: UUID
    public var name: String
    public var score: Int
    public init(formatID: UUID, name: String, score: Int) {
        self.formatID = formatID
        self.name = name
        self.score = score
    }
}

// MARK: - Candidate

/// A search result paired with its parsed name: the unit the quality engine ranks.
public struct ReleaseCandidate: Sendable, Hashable, Identifiable {
    public var release: IndexerRelease
    public var parsed: ParsedRelease
    public var id: String { release.id }

    public init(release: IndexerRelease, parsed: ParsedRelease) {
        self.release = release
        self.parsed = parsed
    }

    /// Parses `release.title` with ``ReleaseParser``.
    public init(release: IndexerRelease) {
        self.init(release: release, parsed: ReleaseParser.parse(release.title))
    }
}

// MARK: - Compilation and evaluation

/// Per-candidate facts for format matching: attribute bitmasks (so a specification check is an AND) and
/// lazily lower-cased title bytes shared by all title/group patterns.
final class CandidateFacts {
    let candidate: ReleaseCandidate
    let source: UInt64, codec: UInt64, hdr: UInt64, audio: UInt64, language: UInt64, edition: UInt64, flags: UInt64
    private var bytes: [UInt8]?

    init(_ candidate: ReleaseCandidate) {
        self.candidate = candidate
        source = candidate.parsed.source.map(Self.bit) ?? 0
        codec = candidate.parsed.videoCodec.map(Self.bit) ?? 0
        hdr = candidate.parsed.hdr.isEmpty ? Self.bit(HDRFormat.sdr) : candidate.parsed.hdr.reduce(0) { $0 | Self.bit($1) }
        audio = candidate.parsed.audioCodecs.reduce(0) { $0 | Self.bit($1) }
        language = candidate.parsed.languages.reduce(0) { $0 | Self.bit($1) }
        edition = candidate.parsed.editions.reduce(0) { $0 | Self.bit($1) }
        var f = candidate.parsed.flags.reduce(0) { $0 | Self.bit($1) }
        if candidate.parsed.version > 1 { f |= Self.bit(ReleaseFlag.proper) }
        flags = f
    }

    /// One bit per case, by declaration order. Payload-free enums are a single tag byte holding that index.
    static func bit<T: CaseIterable>(_ value: T) -> UInt64 {
        withUnsafeBytes(of: value) { 1 << UInt64($0[0]) }
    }

    static func mask<T: RawRepresentable & CaseIterable>(_ values: [T]) -> UInt64 where T.RawValue == String {
        values.reduce(0) { $0 | bit($1) }
    }

    var lowerTitle: [UInt8] {
        if let bytes { return bytes }
        let made = Array(candidate.parsed.input.lowercased().utf8)
        bytes = made
        return made
    }
}

/// Normalizes user-entered names: lower-case, `+` becomes `plus`, everything but letters/digits dropped,
/// then a small alias table is applied.
func qualityNormalize(_ text: String) -> String {
    var out = ""
    for ch in text.lowercased() {
        if ch == "+" { out += "plus" } else if ch.isLetter || ch.isNumber { out.append(ch) }
    }
    return qualityAliases[out] ?? out
}

private let qualityAliases: [String: String] = [
    "x264": "h264", "avc": "h264", "x265": "h265", "hevc": "h265",
    "dv": "dolbyvision", "dovi": "dolbyvision", "hdr10p": "hdr10plus",
    "dd": "ac3", "ddp": "eac3", "dolbydigital": "ac3", "dolbydigitalplus": "eac3",
    "dtshdmasteraudio": "dtshdma",
    "4k": "2160", "uhd": "2160", "2160p": "2160", "1080p": "1080", "720p": "720", "576p": "576", "480p": "480",
    "bd": "bluray", "brrip": "bluray", "bdrip": "bluray", "webdlrip": "webdl", "dvdrip": "dvd",
    "directors": "directorscut", "director": "directorscut",
]

private func qualityLookup<T: RawRepresentable & CaseIterable & Hashable>(_ value: String, as: T.Type) -> [T]
where T.RawValue == String {
    T.allCases.filter { qualityNormalize($0.rawValue) == value }
}

/// A specification with its value resolved to bitmasks/typed values for allocation-free matching.
struct CompiledSpecification {
    enum Check {
        case pattern(PatternMatcher, group: Bool)
        case source(UInt64), codec(UInt64), audio(UInt64), language(UInt64), edition(UInt64), flag(UInt64)
        case hdr(mask: UInt64, anyHDR: Bool)
        case resolution(Int?)
        case channels(String)
        case service(String)
        case indexerFlag(String)
        case size(Double?, Double?)
    }

    let typeIndex: Int
    let check: Check
    let negate: Bool
    let required: Bool

    init(_ spec: FormatSpecification) {
        typeIndex = SpecificationType.allCases.firstIndex(of: spec.type) ?? 0
        negate = spec.negate
        required = spec.required
        let value = qualityNormalize(spec.value)
        switch spec.type {
        case .releaseTitle: check = .pattern(PatternMatcher.make(spec.value, wholeString: false), group: false)
        case .releaseGroup: check = .pattern(PatternMatcher.make(spec.value, wholeString: true), group: true)
        case .source:
            check = .source(
                value == "web" ? CandidateFacts.mask([Source.webDL, .webRip]) : CandidateFacts.mask(qualityLookup(value, as: Source.self)))
        case .resolution:
            check = .resolution(Int(value.hasSuffix("p") ? String(value.dropLast()) : value))
        case .videoCodec: check = .codec(CandidateFacts.mask(qualityLookup(value, as: VideoCodec.self)))
        case .hdr:
            let nonSDR = CandidateFacts.mask(HDRFormat.allCases.filter { $0 != .sdr })
            check = value == "hdr"
                ? .hdr(mask: nonSDR, anyHDR: true)
                : .hdr(mask: CandidateFacts.mask(qualityLookup(value, as: HDRFormat.self)), anyHDR: false)
        case .audioCodec: check = .audio(CandidateFacts.mask(qualityLookup(value, as: AudioCodec.self)))
        case .audioChannels: check = .channels(spec.value.filter(\.isNumber))
        case .language: check = .language(CandidateFacts.mask(qualityLookup(value, as: Language.self)))
        case .edition: check = .edition(CandidateFacts.mask(qualityLookup(value, as: Edition.self)))
        case .streamingService: check = .service(spec.value.uppercased())
        case .indexerFlag: check = .indexerFlag(value)
        case .releaseFlag: check = .flag(CandidateFacts.mask(qualityLookup(value, as: ReleaseFlag.self)))
        case .size: check = .size(spec.min, spec.max)
        }
    }

    func passes(_ f: CandidateFacts) -> Bool {
        raw(f) != negate
    }

    private func raw(_ f: CandidateFacts) -> Bool {
        switch check {
        case .source(let m): return f.source & m != 0
        case .codec(let m): return f.codec & m != 0
        case .audio(let m): return f.audio & m != 0
        case .language(let m): return f.language & m != 0
        case .edition(let m): return f.edition & m != 0
        case .flag(let m): return f.flags & m != 0 && m != 0
        case .hdr(let m, _): return f.hdr & m != 0
        case .resolution(let r): return r != nil && f.candidate.parsed.resolution?.rawValue == r
        case .pattern(let matcher, let group):
            if group {
                guard let g = f.candidate.parsed.releaseGroup else { return false }
                return matcher.matches(Array(g.lowercased().utf8), original: g)
            }
            return matcher.matches(f.lowerTitle, original: f.candidate.parsed.input)
        case .channels(let v): return !v.isEmpty && f.candidate.parsed.audioChannels?.filter(\.isNumber) == v
        case .service(let v): return f.candidate.parsed.streamingService?.uppercased() == v
        case .indexerFlag(let v):
            let r = f.candidate.release
            switch v {
            case "freeleech": return r.downloadVolumeFactor == 0
            case "halfleech": return (r.downloadVolumeFactor ?? 1) > 0 && (r.downloadVolumeFactor ?? 1) < 1
            case "doubleupload": return (r.uploadVolumeFactor ?? 1) >= 2
            default: return false
            }
        case .size(let lo, let hi):
            guard let bytes = f.candidate.release.size else { return false }
            let gib = Double(bytes) / 1_073_741_824
            return (lo.map { gib >= $0 } ?? true) && (hi.map { gib <= $0 } ?? true)
        }
    }
}

/// A format ready for repeated evaluation.
struct CompiledFormat {
    let id: UUID
    let name: String
    let specs: [CompiledSpecification]
    /// Bitmask of specification types that have at least one non-required specification.
    private let optionalMask: UInt32

    init(_ format: CustomFormatConfig) {
        id = format.id
        name = format.name
        specs = format.specifications.map(CompiledSpecification.init)
        optionalMask = specs.filter { !$0.required }.reduce(0) { $0 | (1 << UInt32($1.typeIndex)) }
    }

    func matches(_ f: CandidateFacts) -> Bool {
        if specs.isEmpty { return false }
        var optionalPassed: UInt32 = 0
        for spec in specs {
            let ok = spec.passes(f)
            if spec.required {
                if !ok { return false }
            } else if ok {
                optionalPassed |= 1 << UInt32(spec.typeIndex)
            }
        }
        return optionalPassed & optionalMask == optionalMask
    }
}

// MARK: - Pattern matching

/// Case-insensitive pattern matcher. Plain alternations of literals (the overwhelmingly common shape of
/// release-group and keyword formats, e.g. `\b(SubsPlease|Erai-raws)\b`) run on a byte-level fast path;
/// anything else falls back to `NSRegularExpression`.
final class PatternMatcher: @unchecked Sendable {
    private enum Storage {
        case literals([[UInt8]], boundaryStart: Bool, boundaryEnd: Bool, anchorStart: Bool, anchorEnd: Bool)
        case regex(NSRegularExpression)
        case invalid
    }

    private let storage: Storage

    private init(_ storage: Storage) { self.storage = storage }

    var isValid: Bool {
        if case .invalid = storage { return false }
        return true
    }

    private static let cache = Mutex<[String: PatternMatcher]>([:])

    static func make(_ pattern: String, wholeString: Bool) -> PatternMatcher {
        let key = (wholeString ? "w:" : "s:") + pattern
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let made = build(pattern, wholeString: wholeString)
        cache.withLock { $0[key] = made }
        return made
    }

    private static func build(_ pattern: String, wholeString: Bool) -> PatternMatcher {
        if pattern.isEmpty { return PatternMatcher(.invalid) }
        if let fast = parseLiterals(pattern, wholeString: wholeString) { return fast }
        let full = wholeString ? "^(?:\(pattern))$" : pattern
        guard let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) else {
            return PatternMatcher(.invalid)
        }
        return PatternMatcher(.regex(regex))
    }

    /// Recognizes `^? \b? (?:( a|b|c ))? \b? $?` where each alternative is plain text.
    private static func parseLiterals(_ pattern: String, wholeString: Bool) -> PatternMatcher? {
        var p = Substring(pattern)
        var anchorStart = wholeString, anchorEnd = wholeString
        if p.hasPrefix("^") { anchorStart = true; p = p.dropFirst() }
        if p.hasSuffix("$") && !p.hasSuffix("\\$") { anchorEnd = true; p = p.dropLast() }
        var boundaryStart = false, boundaryEnd = false
        if p.hasPrefix("\\b") { boundaryStart = true; p = p.dropFirst(2) }
        if p.hasSuffix("\\b") { boundaryEnd = true; p = p.dropLast(2) }
        if p.hasPrefix("(?:") && p.hasSuffix(")") { p = p.dropFirst(3).dropLast() }
        else if p.hasPrefix("(") && p.hasSuffix(")") { p = p.dropFirst().dropLast() }
        var alts: [[UInt8]] = []
        for alt in p.split(separator: "|", omittingEmptySubsequences: false) {
            var bytes: [UInt8] = []
            var iterator = alt.lowercased().utf8.makeIterator()
            while let b = iterator.next() {
                switch b {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                    UInt8(ascii: " "), UInt8(ascii: "_"), UInt8(ascii: "-"):
                    bytes.append(b)
                case UInt8(ascii: "\\"):
                    guard let next = iterator.next(), next == UInt8(ascii: ".") else { return nil }
                    bytes.append(next)
                default:
                    return nil
                }
            }
            guard let first = bytes.first, let last = bytes.last else { return nil }
            if (boundaryStart && !isWordByte(first)) || (boundaryEnd && !isWordByte(last)) { return nil }
            alts.append(bytes)
        }
        if alts.isEmpty { return nil }
        return PatternMatcher(.literals(alts, boundaryStart: boundaryStart, boundaryEnd: boundaryEnd,
                                        anchorStart: anchorStart, anchorEnd: anchorEnd))
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == UInt8(ascii: "_")
    }

    /// `lower` is the lower-cased UTF-8 of `original`.
    func matches(_ lower: [UInt8], original: @autoclosure () -> String) -> Bool {
        switch storage {
        case .invalid: return false
        case .regex(let regex):
            let text = original()
            return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
        case .literals(let alts, let bs, let be, let aStart, let aEnd):
            let n = lower.count
            for alt in alts {
                let m = alt.count
                if m > n { continue }
                if aStart && aEnd {
                    if m == n && matchAt(lower, 0, alt, bs, be) { return true }
                } else if aStart {
                    if matchAt(lower, 0, alt, bs, be) { return true }
                } else if aEnd {
                    if matchAt(lower, n - m, alt, bs, be) { return true }
                } else {
                    var i = 0
                    while i <= n - m {
                        if matchAt(lower, i, alt, bs, be) { return true }
                        i += 1
                    }
                }
            }
            return false
        }
    }

    private func matchAt(_ s: [UInt8], _ i: Int, _ alt: [UInt8], _ bs: Bool, _ be: Bool) -> Bool {
        let m = alt.count
        var k = 0
        while k < m {
            if s[i + k] != alt[k] { return false }
            k += 1
        }
        if bs && i > 0 && Self.isWordByte(s[i - 1]) { return false }
        if be && i + m < s.count && Self.isWordByte(s[i + m]) { return false }
        return true
    }
}
