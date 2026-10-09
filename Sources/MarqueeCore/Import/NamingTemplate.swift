import Foundation

/// A problem in a naming template, for the settings screen.
public struct NamingIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case unknownToken(String)
        case unbalancedBrace
        case missingExtension
        case noEpisodeIdentity
        case emptyTemplate
    }

    public var kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    /// Plain-language text.
    public var description: String {
        switch kind {
        case .unknownToken(let name): "\"{\(name)}\" isn't a known token and will be left out."
        case .unbalancedBrace: "A curly brace is not closed; it will be kept as text."
        case .missingExtension: "The template doesn't end with {ext}; the original extension will be added."
        case .noEpisodeIdentity: "The template doesn't say which episode this is, so episodes could end up with the same name."
        case .emptyTemplate: "The template is empty."
        }
    }
}

/// The result of rendering a template: folders then the file name, each already safe to use.
public struct RenderedName: Sendable, Hashable {
    public var components: [String]
    public var warnings: [String]

    /// Folder components, outermost first.
    public var folders: [String] { Array(components.dropLast()) }
    public var fileName: String { components.last ?? "" }
    /// `Folder/Sub/File.ext`, relative to a root folder.
    public var relativePath: String { components.joined(separator: "/") }
}

/// A parsed naming template (`{Series Title} - S{season:00}E{episode:00}.{ext}`).
///
/// Syntax:
/// - `{Token}` inserts a value; token names ignore case, spaces, dashes and dots (`{Air-Date}` = `{air date}`).
/// - `{season:00}` pads numbers to a width; `{Episode Title:30}` limits text to 30 characters;
///   `{Series Title:upper}` / `:lower` change case.
/// - `[...]` and `(...)` groups containing tokens vanish, brackets included, when every token inside is empty.
/// - `{{` and `}}` are literal braces. `/` starts a new folder level.
///
/// Tokens: Series Title, Movie Title, Title, Series TitleYear, Series CleanTitle, Movie CleanTitle, Year,
/// Release Year, season, episode, absolute, Air-Date, Episode Title, Episode CleanTitle, Quality Full,
/// Quality Title, Source, Resolution, Release Group, Edition Tags, Edition Plex, HDR, Video Codec,
/// Audio Codec, Audio Channels, Streaming Service, Languages, Proper, Original Filename, ext.
public struct NamingTemplate: Sendable, Hashable {
    indirect enum Node: Sendable, Hashable {
        case literal(String)
        case token(name: String, key: String, format: String?)
        case group(open: Character, close: Character, [Node])
        case separator
    }

    public let source: String
    let nodes: [Node]
    /// Problems found while parsing (unknown tokens, unbalanced braces).
    public let parseIssues: [NamingIssue]

    public init(_ source: String) {
        self.source = source
        var issues: [NamingIssue] = []
        nodes = Self.parse(source, issues: &issues)
        parseIssues = issues
    }

    // MARK: Validation

    /// Parse problems plus structural ones (no `{ext}`, nothing identifying the episode).
    public func validate(forEpisodes: Bool = false) -> [NamingIssue] {
        var issues = parseIssues
        if source.trimmingCharacters(in: .whitespaces).isEmpty { return [NamingIssue(.emptyTemplate)] }
        let keys = Set(allTokens(nodes).map(\.key))
        if !keys.contains("ext") && !keys.contains("extension") { issues.append(NamingIssue(.missingExtension)) }
        if forEpisodes, keys.isDisjoint(with: ["episode", "airdate", "absolute", "episodetitle", "originalfilename"]) {
            issues.append(NamingIssue(.noEpisodeIdentity))
        }
        return issues
    }

    private func allTokens(_ nodes: [Node]) -> [(name: String, key: String)] {
        nodes.flatMap { node -> [(String, String)] in
            switch node {
            case .token(let name, let key, _): [(name, key)]
            case .group(_, _, let inner): allTokens(inner)
            default: []
            }
        }
    }

    // MARK: Parsing

    private static func parse(_ source: String, issues: inout [NamingIssue]) -> [Node] {
        let chars = Array(source)
        var stack: [(open: Character, close: Character, nodes: [Node])] = [("\0", "\0", [])]
        var literal = ""

        func flush() {
            if !literal.isEmpty {
                stack[stack.count - 1].nodes.append(.literal(literal))
                literal = ""
            }
        }
        func hasCloser(_ close: Character, after index: Int) -> Bool {
            var i = index + 1
            while i < chars.count {
                if chars[i] == close { return true }
                if chars[i] == "{" { while i < chars.count && chars[i] != "}" { i += 1 } }
                i += 1
            }
            return false
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "{":
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    literal.append("{")
                    i += 2
                    continue
                }
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else {
                    issues.append(NamingIssue(.unbalancedBrace))
                    literal.append(contentsOf: chars[i...])
                    i = chars.count
                    continue
                }
                let inner = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)
                flush()
                let (name, format) = splitToken(inner)
                let key = normalizeKey(name)
                if !knownKeys.contains(key) { issues.append(NamingIssue(.unknownToken(name))) }
                stack[stack.count - 1].nodes.append(.token(name: name, key: key, format: format))
                i = end + 1
                continue
            case "}":
                if i + 1 < chars.count, chars[i + 1] == "}" {
                    literal.append("}")
                    i += 2
                    continue
                }
                issues.append(NamingIssue(.unbalancedBrace))
                literal.append("}")
            case "[", "(":
                let close: Character = c == "[" ? "]" : ")"
                if hasCloser(close, after: i) {
                    flush()
                    stack.append((c, close, []))
                } else {
                    literal.append(c)
                }
            case "]", ")":
                if stack.count > 1, stack[stack.count - 1].close == c {
                    flush()
                    let done = stack.removeLast()
                    stack[stack.count - 1].nodes.append(.group(open: done.open, close: done.close, done.nodes))
                } else {
                    literal.append(c)
                }
            case "/":
                if stack.count == 1 {
                    flush()
                    stack[0].nodes.append(.separator)
                } else {
                    literal.append(c)
                }
            default:
                literal.append(c)
            }
            i += 1
        }
        flush()
        // Groups left open (can't happen: openers need a closer) fold back as text.
        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].nodes.append(.literal(String(done.open)))
            stack[stack.count - 1].nodes.append(contentsOf: done.nodes)
        }
        return stack[0].nodes
    }

    private static func splitToken(_ inner: String) -> (name: String, format: String?) {
        guard let colon = inner.firstIndex(of: ":") else { return (inner, nil) }
        return (
            String(inner[..<colon]).trimmingCharacters(in: .whitespaces),
            String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    static func normalizeKey(_ name: String) -> String {
        String(name.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" && $0 != "." })
    }

    static let knownKeys: Set<String> = [
        "seriestitle", "movietitle", "title", "seriestitleyear", "seriescleantitle", "moviecleantitle", "cleantitle",
        "year", "releaseyear", "seriesyear", "season", "episode", "absolute", "absoluteepisode", "airdate",
        "episodetitle", "episodecleantitle", "qualityfull", "qualitytitle", "source", "resolution", "releasegroup",
        "editiontags", "edition", "editionplex", "hdr", "videocodec", "audiocodec", "audiochannels",
        "streamingservice", "languages", "proper", "originalfilename", "ext", "extension",
    ]

    // MARK: Rendering

    /// Renders for `context`. Components are sanitized and length-limited; the file name always keeps
    /// the context's extension.
    public func render(_ context: NamingContext, config: NamingConfig = .default) -> RenderedName {
        var warnings: [String] = []
        var titleCap: Int?
        var components = renderComponents(context, config, titleCap: titleCap)
        let limit = max(32, config.maxComponentBytes)

        // Over-long file name: shorten the episode title first (it is the most expendable part).
        let fullTitle = Self.episodeTitle(context)
        for _ in 0..<3 {
            guard let file = components.last, file.utf8.count > limit, !fullTitle.isEmpty else { break }
            let current = titleCap ?? fullTitle.count
            if current == 0 { break }
            titleCap = max(0, current - (file.utf8.count - limit))
            components = renderComponents(context, config, titleCap: titleCap)
            warnings.append("The episode title was shortened to fit the file name length limit.")
        }

        var fitted: [String] = []
        for (index, component) in components.enumerated() {
            let isFile = index == components.count - 1
            let extensionPart = isFile ? "." + context.ext : ""
            let (result, truncated) = Self.fit(component, limit: limit, keepSuffix: extensionPart)
            if truncated { warnings.append("\"\(result)\" was shortened to fit the name length limit.") }
            fitted.append(result)
        }
        var seen = Set<String>()
        return RenderedName(components: fitted, warnings: warnings.filter { seen.insert($0).inserted })
    }

    private func renderComponents(_ context: NamingContext, _ config: NamingConfig, titleCap: Int?) -> [String] {
        var parts: [[Node]] = [[]]
        for node in nodes {
            if case .separator = node { parts.append([]) } else { parts[parts.count - 1].append(node) }
        }
        let renderer = Renderer(context: context, config: config, episodeTitleCap: titleCap)
        var out: [String] = []
        for (index, part) in parts.enumerated() {
            let isFile = index == parts.count - 1
            var text = renderer.render(part).text
            let suffix = "." + context.ext
            if isFile, text.lowercased().hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
            var cleaned = Renderer.finishComponent(text, config: config, isFile: isFile)
            if isFile {
                if cleaned.isEmpty { cleaned = "Unknown" }
                cleaned += suffix
            } else if cleaned.isEmpty {
                continue
            }
            out.append(cleaned)
        }
        if out.isEmpty { out = ["Unknown." + context.ext] }
        return out
    }

    static func episodeTitle(_ context: NamingContext) -> String {
        context.episodeTitles.filter { !$0.isEmpty }.joined(separator: " + ")
    }

    /// Cuts `text` to `limit` UTF-8 bytes, keeping `keepSuffix` (the extension) intact and never splitting a character.
    static func fit(_ text: String, limit: Int, keepSuffix: String) -> (String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        let stemSource = keepSuffix.isEmpty || !text.hasSuffix(keepSuffix) ? text : String(text.dropLast(keepSuffix.count))
        let budget = limit - (stemSource.count == text.count ? 0 : keepSuffix.utf8.count)
        var stem = ""
        var used = 0
        for ch in stemSource {
            let n = String(ch).utf8.count
            if used + n > budget { break }
            stem.append(ch)
            used += n
        }
        while let last = stem.last, last == " " || last == "." || last == "-" || last == "_" { stem.removeLast() }
        return (stem + (stemSource.count == text.count ? "" : keepSuffix), true)
    }
}

// MARK: - Renderer

private struct Renderer {
    let context: NamingContext
    let config: NamingConfig
    let episodeTitleCap: Int?

    struct Output {
        var text = ""
        var tokenCount = 0
        var nonEmptyTokens = 0
    }

    func render(_ nodes: [NamingTemplate.Node]) -> Output {
        var out = Output()
        for node in nodes {
            switch node {
            case .literal(let s):
                out.text += Self.sanitize(s, config: config, isLiteral: true)
            case .separator:
                out.text += "/"
            case .token(_, let key, let format):
                out.tokenCount += 1
                let value = tokenValue(key: key, format: format)
                if !value.isEmpty { out.nonEmptyTokens += 1 }
                out.text += Self.sanitize(value, config: config, isLiteral: false)
            case .group(let open, let close, let inner):
                let rendered = render(inner)
                out.tokenCount += rendered.tokenCount
                out.nonEmptyTokens += rendered.nonEmptyTokens
                if rendered.tokenCount > 0 && rendered.nonEmptyTokens == 0 { continue }
                out.text += String(open) + rendered.text + String(close)
            }
        }
        return out
    }

    // MARK: Token values

    private func tokenValue(key: String, format: String?) -> String {
        let c = context
        let p = c.effectiveParsed
        func text(_ s: String?) -> String { applyTextFormat(s ?? "", format) }
        switch key {
        case "seriestitle", "movietitle", "title": return text(c.title)
        case "seriestitleyear": return text(c.year.map { "\(c.title) (\($0))" } ?? c.title)
        case "seriescleantitle", "moviecleantitle", "cleantitle": return text(Self.cleanTitle(c.title))
        case "year", "releaseyear", "seriesyear": return c.year.map { number($0, format) } ?? ""
        case "season": return c.season.map { number($0, format) } ?? ""
        case "episode": return episodeNumbers(format)
        case "absolute", "absoluteepisode": return absoluteNumbers(format)
        case "airdate": return c.airDate?.description ?? ""
        case "episodetitle":
            var title = NamingTemplate.episodeTitle(c)
            if let cap = episodeTitleCap, title.count > cap { title = String(title.prefix(cap)) }
            return text(title)
        case "episodecleantitle": return text(Self.cleanTitle(NamingTemplate.episodeTitle(c)))
        case "qualityfull":
            let tier = c.tier
            var label = tier.fileLabel
            if p.flags.contains(.repack) { label += " Repack" } else if p.isProperOrRepack { label += " Proper" }
            return text(label)
        case "qualitytitle", "source": return text(c.tier.sourceLabel)
        case "resolution":
            if let r = p.resolution { return "\(r.rawValue)p" }
            let r = c.tier.resolution
            return r > 0 ? "\(r)p" : ""
        case "releasegroup": return text(p.releaseGroup)
        case "editiontags", "edition": return text(p.editions.map(\.displayName).joined(separator: " "))
        case "editionplex":
            let names = p.editions.map(\.displayName).joined(separator: " ")
            return names.isEmpty ? "" : "{edition-\(names)}"
        case "hdr": return text(Self.hdrLabel(p, media: c.media))
        case "videocodec": return text(Self.videoCodecLabel(p, media: c.media))
        case "audiocodec": return text(Self.audioCodecLabel(p, media: c.media))
        case "audiochannels": return text(Self.channelLabel(p, media: c.media))
        case "streamingservice": return text(p.streamingService)
        case "languages":
            let langs = p.languages.filter { $0 != .english }
            return text(langs.map { $0 == .multi ? "MULTi" : $0.rawValue.capitalized }.joined(separator: " "))
        case "proper":
            if p.flags.contains(.repack) { return text("Repack") }
            return p.isProperOrRepack ? text("Proper") : ""
        case "originalfilename":
            let name = c.originalFilename as NSString
            return text(name.deletingPathExtension)
        case "ext", "extension": return c.ext
        default: return ""
        }
    }

    private func number(_ value: Int, _ format: String?) -> String {
        let width = format.flatMap { f in !f.isEmpty && f.allSatisfy({ $0 == "0" }) ? f.count : nil } ?? 1
        let digits = String(abs(value))
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private func applyTextFormat(_ value: String, _ format: String?) -> String {
        guard let format, !value.isEmpty else { return value }
        switch format.lowercased() {
        case "upper": return value.uppercased()
        case "lower": return value.lowercased()
        default:
            if let limit = Int(format), limit > 0, value.count > limit { return String(value.prefix(limit)).trimmingCharacters(in: .whitespaces) }
            return value
        }
    }

    private func episodeNumbers(_ format: String?) -> String {
        let eps = context.episodes
        guard let first = eps.first, let last = eps.last else { return "" }
        func pad(_ n: Int) -> String { number(n, format) }
        guard eps.count > 1 else { return pad(first) }
        let contiguous = eps == Array(first...last)
        switch config.multiEpisodeStyle {
        case .prefixedRange:
            return contiguous ? "\(pad(first))-E\(pad(last))" : eps.map(pad).joined(separator: "E")
        case .range:
            return contiguous ? "\(pad(first))-\(pad(last))" : eps.map(pad).joined(separator: "E")
        case .repeated:
            return eps.map(pad).joined(separator: "E")
        case .extend:
            return eps.map(pad).joined(separator: "-")
        case .duplicate:
            let season = number(context.season ?? 0, "00")
            return pad(first) + eps.dropFirst().map { ".S\(season)E\(pad($0))" }.joined()
        }
    }

    private func absoluteNumbers(_ format: String?) -> String {
        let nums = context.absoluteEpisodes
        guard let first = nums.first, let last = nums.last else { return "" }
        return nums.count == 1 ? number(first, format) : "\(number(first, format))-\(number(last, format))"
    }

    // MARK: Labels

    static func cleanTitle(_ title: String) -> String {
        let kept = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func hdrLabel(_ p: ParsedRelease, media: MediaInfo?) -> String {
        let formats = p.hdr.filter { $0 != .sdr }
        if !formats.isEmpty {
            let names = formats.map { f -> String in
                switch f {
                case .dolbyVision: "DV"
                case .hdr10Plus: "HDR10Plus"
                case .hdr10: "HDR10"
                case .hlg: "HLG"
                case .hdr: "HDR"
                case .sdr: ""
                }
            }
            return names.joined(separator: " ")
        }
        return media?.hdr ?? ""
    }

    static func videoCodecLabel(_ p: ParsedRelease, media: MediaInfo?) -> String {
        if let raw = media?.videoCodec?.lowercased(), !raw.isEmpty {
            if raw.contains("hevc") || raw.contains("h265") || raw.contains("265") { return "H265" }
            if raw.contains("h264") || raw.contains("avc") || raw.contains("264") { return "H264" }
            if raw.contains("av1") { return "AV1" }
            if raw.contains("vp9") { return "VP9" }
            if raw.contains("mpeg2") { return "MPEG2" }
            if raw.contains("vc1") { return "VC1" }
            return raw.uppercased()
        }
        switch p.videoCodec {
        case .h264?: return "H264"
        case .h265?: return "H265"
        case .av1?: return "AV1"
        case .vp9?: return "VP9"
        case .xvid?: return "XviD"
        case .divx?: return "DivX"
        case .mpeg2?: return "MPEG2"
        case .vc1?: return "VC1"
        case nil: return ""
        }
    }

    static func audioCodecLabel(_ p: ParsedRelease, media: MediaInfo?) -> String {
        if let a = p.audioCodecs.first {
            switch a {
            case .aac: return "AAC"
            case .ac3: return "AC3"
            case .eac3: return "EAC3"
            case .dts: return "DTS"
            case .dtsHD: return "DTS-HD"
            case .dtsHDMA: return "DTS-HD MA"
            case .dtsX: return "DTS-X"
            case .trueHD: return "TrueHD"
            case .atmos: return "Atmos"
            case .flac: return "FLAC"
            case .opus: return "Opus"
            case .mp3: return "MP3"
            case .pcm: return "PCM"
            }
        }
        guard let raw = media?.audioTracks.first?.codec.lowercased(), !raw.isEmpty else { return "" }
        switch raw {
        case "aac": return "AAC"
        case "ac3": return "AC3"
        case "eac3": return "EAC3"
        case "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        default: return raw.uppercased()
        }
    }

    static func channelLabel(_ p: ParsedRelease, media: MediaInfo?) -> String {
        if let c = p.audioChannels { return c }
        switch media?.audioTracks.first?.channels {
        case 1?: return "1.0"
        case 2?: return "2.0"
        case 6?: return "5.1"
        case 8?: return "7.1"
        default: return ""
        }
    }

    // MARK: Sanitizing

    private static let windowsReserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { names.insert("COM\(n)"); names.insert("LPT\(n)") }
        return names
    }()

    /// Replaces what the file system (or the portable policy) refuses. Applied to token values and to
    /// the template's own text; `/` is handled by the caller (path separators are structure).
    static func sanitize(_ s: String, config: NamingConfig, isLiteral: Bool) -> String {
        if s.isEmpty { return s }
        var text = s.precomposedStringWithCanonicalMapping
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0, 1..<0x20, 0x7F: out += scalar == "\t" ? " " : ""
            default: out.unicodeScalars.append(scalar)
            }
        }
        text = out
        if !isLiteral { text = text.replacingOccurrences(of: "/", with: "-") }
        if config.characters == .portable {
            text = text.replacingOccurrences(of: "\\", with: "-")
                .replacingOccurrences(of: "|", with: "-")
                .replacingOccurrences(of: "\"", with: "'")
            for bad in ["*", "?", "<", ">"] { text = text.replacingOccurrences(of: bad, with: "") }
        }
        switch config.colon {
        case .smart:
            text = text.replacingOccurrences(of: ": ", with: " - ").replacingOccurrences(of: " :", with: " -")
                .replacingOccurrences(of: ":", with: "-")
        case .dash: text = text.replacingOccurrences(of: ":", with: " - ")
        case .delete: text = text.replacingOccurrences(of: ":", with: "")
        case .lookalike: text = text.replacingOccurrences(of: ":", with: "\u{A789}")
        }
        return text
    }

    /// Tidies a rendered folder or file name: collapses spaces, drops separators left dangling by empty
    /// tokens, strips leading dots (hidden files) and, for the portable policy, trailing dots and
    /// reserved device names.
    static func finishComponent(_ text: String, config: NamingConfig, isFile: Bool) -> String {
        var s = text.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Separators left with nothing between them: " - - " and " -  - ".
        while s.contains(" - - ") { s = s.replacingOccurrences(of: " - - ", with: " - ") }
        s = s.replacingOccurrences(of: "\\[\\s*\\]|\\(\\s*\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*[-–]\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+[-–]\\s*$", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if config.characters == .portable {
            while let last = s.last, last == "." || last == " " { s.removeLast() }
            if windowsReserved.contains(s.uppercased()) { s += "_" }
        }
        if let space = config.spaces { s = s.replacingOccurrences(of: " ", with: space.rawValue) }
        return s
    }
}

// MARK: - Convenience

extension NamingConfig {
    /// Renders the right template for `context`.
    public func render(_ context: NamingContext) -> RenderedName {
        NamingTemplate(template(for: context)).render(context, config: self)
    }

    /// Problems in the four templates, for the settings screen.
    public func validate() -> [NamingIssue] {
        var all = NamingTemplate(movieTemplate).validate()
        for t in [episodeTemplate, dailyTemplate, animeTemplate] {
            all.append(contentsOf: NamingTemplate(t).validate(forEpisodes: true))
        }
        var seen = Set<NamingIssue>()
        return all.filter { seen.insert($0).inserted }
    }
}
