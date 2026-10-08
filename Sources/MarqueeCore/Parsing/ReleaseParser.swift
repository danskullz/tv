/// Parses release names and torrent file paths into `ParsedRelease`.
///
/// Pure and deterministic: no I/O, no global mutable state. Implemented as a hand-written
/// byte-level tokenizer with dictionary lookups (no regex engine) so a name costs a few microseconds.
public enum ReleaseParser {
    /// Parse a single release name or file name. If `name` contains a `/` it is treated as a path
    /// and routed through ``parseFileName(_:)``.
    public static func parse(_ name: String) -> ParsedRelease {
        if name.utf8.contains(0x2F) { return parseFileName(name) }
        return parseCore(name, lenient: false)
    }

    /// Lower-case, punctuation-free title for matching: "Marvel's Agents of S.H.I.E.L.D." -> "marvels agents of shield".
    public static func normalizeTitle(_ title: String) -> String {
        var out = ""
        out.reserveCapacity(title.utf8.count)
        var pendingSpace = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" || ch == "." {
                continue
            } else if ch == "&" {
                if !out.isEmpty { out.append(" ") }
                out.append("and")
                pendingSpace = true
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    // MARK: Core

    static func parseCore(_ name: String, lenient: Bool) -> ParsedRelease {
        let bytes = Array(name.utf8)
        var lo = 0
        var hi = bytes.count
        var r = ParsedRelease(input: name)
        var fileKind: FileKind?

        // File extension
        if let dot = lastDot(bytes, lo, hi) {
            let extLen = hi - dot - 1
            if extLen >= 1 && extLen <= 5 {
                var e = Array(bytes[(dot + 1)..<hi])
                for i in 0..<e.count where e[i] >= 65 && e[i] <= 90 { e[i] += 32 }
                let ext = String(decoding: e, as: UTF8.self)
                if let k = Vocabulary.extensions[ext] {
                    r.container = ext
                    fileKind = k
                    hi = dot
                    if k == .archive { dropPartSuffix(bytes, &hi) }
                } else if e.count == 3, e[0] == 0x72, e[1] >= 0x30, e[1] <= 0x39, e[2] >= 0x30, e[2] <= 0x39 {
                    r.container = ext
                    fileKind = .archive
                    hi = dot
                    dropPartSuffix(bytes, &hi)
                }
            }
        }
        switch fileKind {
        case .subtitle?: r.flags.insert(.subtitleFile)
        case .archive?: r.flags.insert(.archive)
        case .nonMedia?: r.flags.insert(.nonMedia)
        default: break
        }

        // Leading whitespace, site prefixes and bracketed release group
        while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 { lo += 1 }
        var hasPrefixGroup = false
        var prefixGroup: String?
        prefixLoop: while lo < hi {
            if hasPrefix(bytes, lo, hi, "www.") {
                var p = lo
                var found = false
                while p + 2 < hi {
                    if bytes[p] == 0x20, bytes[p + 1] == 0x2D, bytes[p + 2] == 0x20 { found = true; break }
                    p += 1
                }
                if found { lo = p + 3; continue prefixLoop }
                break
            }
            let (open, openLen) = bracketOpen(bytes, lo, hi)
            if open == 0 { break }
            // find the closing bracket
            var q = lo + openLen
            var closeLen = 1
            var foundClose = false
            while q < hi {
                let c = bytes[q]
                if c == 0x5D || c == 0x29 || c == 0x7D { foundClose = true; closeLen = 1; break }
                if c == 0xE3, q + 2 < hi, bytes[q + 1] == 0x80, bytes[q + 2] == 0x91 { foundClose = true; closeLen = 3; break }
                q += 1
            }
            guard foundClose, open == 0x5B || open == 0xE3 else { break }
            let content = String(decoding: bytes[(lo + openLen)..<q], as: UTF8.self)
            let lower = content.lowercased().trimmingSpaces()
            if isSiteLike(lower) || Vocabulary.siteTags.contains(lower) {
                lo = q + closeLen
                while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x2D || bytes[lo] == 0x5F { lo += 1 }
                continue
            }
            if !prefixGroupRejected(lower) && !hasPrefixGroup {
                hasPrefixGroup = true
                prefixGroup = content.trimmingSpaces()
                lo = q + closeLen
                while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x5F { lo += 1 }
                // A second leading bracket is usually a quality tag, not part of the title.
                continue
            }
            break
        }

        // Trailing site tags / re-post suffixes / duplicate markers
        var tagGroup: String?
        trailLoop: while hi > lo {
            let last = bytes[hi - 1]
            if last == 0x20 || last == 0x2E || last == 0x2D || last == 0x5F { hi -= 1; continue }
            if last == 0x5D || last == 0x29 {
                let openCh: UInt8 = last == 0x5D ? 0x5B : 0x28
                var p = hi - 2
                while p >= lo, bytes[p] != openCh { p -= 1 }
                if p >= lo {
                    let content = String(decoding: bytes[(p + 1)..<(hi - 1)], as: UTF8.self).lowercased().trimmingSpaces()
                    if Vocabulary.siteTags.contains(content) || isSiteLike(content) {
                        hi = p; continue
                    }
                    if content.hasPrefix("yts") || content.hasPrefix("yify") {
                        tagGroup = content.hasPrefix("yts") ? "YTS" : "YIFY"
                        hi = p; continue
                    }
                    if !content.isEmpty, content.utf8.count <= 2, content.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), p > lo, bytes[p - 1] == 0x20 {
                        hi = p; continue
                    }
                }
                break trailLoop
            }
            for suf in Vocabulary.repostSuffixes where hasSuffixCI(bytes, lo, hi, suf) {
                hi -= suf.utf8.count
                continue trailLoop
            }
            break
        }

        var sc = Scanner(bytes: bytes, lo: lo, hi: hi, hasPrefixGroup: hasPrefixGroup, lenient: lenient)
        sc.tokenize()
        sc.computeTitleEnd()
        sc.classifyAll()
        let n = sc.toks.count

        // Samples, extras
        for k in 0..<n {
            let l = sc.toks[k].l
            if l == "sample" || l == "samples" {
                if k == 0 || k >= sc.titleEnd || k == n - 1 { sc.flags.insert(.sample) }
            } else if k >= sc.titleEnd && Vocabulary.extrasWords.contains(l) {
                sc.flags.insert(.extra)
            } else if (l.hasPrefix("ncop") || l.hasPrefix("nced")) && k >= 1 {
                sc.flags.insert(.extra)
            }
        }

        // Release group
        var group = prefixGroup
        if group == nil {
            group = sc.findTailGroup()
            if group == nil { group = tagGroup }
        }
        if let g = group, g.isEmpty { group = nil }

        // Title
        r.title = sc.render(0, sc.titleEnd)
        if sc.titleEnd >= n && sc.flags.isDisjoint(with: [.sample, .extra]) {
            let nt = normalizeTitle(r.title)
            if Vocabulary.extrasWords.contains(nt) || nt == "sample" || nt == "samples" {
                sc.flags.insert(nt.hasPrefix("sample") ? .sample : .extra)
            }
        }
        if sc.epEnd >= 0 {
            var k = sc.epEnd
            var end = k
            while end < n, !sc.toks[end].used { end += 1 }
            if end > k {
                // skip leading separator-only tokens (none exist) and render
                let t = sc.render(k, end)
                if !t.isEmpty { r.episodeTitle = t }
            }
            k = end
        }

        // Unparsed tokens
        if sc.titleEnd < n {
            for k in sc.titleEnd..<n where !sc.toks[k].used {
                r.unparsedTokens.append(String(decoding: sc.b[sc.toks[k].s..<sc.toks[k].e], as: UTF8.self))
            }
        }

        r.year = sc.year
        r.seasons = sc.seasons
        r.episodes = sc.episodes
        r.absoluteEpisodes = sc.absolute
        r.airDate = sc.airDate
        r.isSpecial = sc.special || sc.seasons == [0]
        r.resolution = sc.resolution
        r.source = sc.source
        r.videoCodec = sc.videoCodec
        var hdr = sc.hdr
        if hdr.contains(.hdr10) || hdr.contains(.hdr10Plus) { hdr.removeAll { $0 == .hdr } }
        r.hdr = hdr
        r.bitDepth = sc.bitDepth
        r.audioCodecs = sc.audio
        r.audioChannels = sc.channels
        r.languages = sc.languages
        r.releaseGroup = group
        r.crc32 = sc.crc
        r.version = sc.version
        r.editions = sc.editions
        r.streamingService = sc.service
        r.flags.formUnion(sc.flags)
        decideKind(&r, completePhrase: sc.completePhrase, completeWord: sc.completeWord)
        return r
    }

    static func decideKind(_ r: inout ParsedRelease, completePhrase: Bool, completeWord: Bool) {
        if r.airDate != nil {
            r.kind = .daily
        } else if !r.episodes.isEmpty {
            r.kind = .episode
        } else if !r.absoluteEpisodes.isEmpty {
            r.kind = .animeAbsolute
        } else if r.seasons.count > 1 {
            r.kind = .multiSeason
        } else if r.seasons.count == 1 {
            r.kind = .seasonPack
        } else if completePhrase || (completeWord && r.year == nil) {
            r.kind = .completeSeries
        } else if r.flags.contains(.batch) {
            r.kind = .seasonPack
        } else if r.year != nil || r.resolution != nil || r.source != nil || r.videoCodec != nil {
            r.kind = .movie
        } else {
            r.kind = .unknown
        }
    }

    // MARK: Byte helpers

    private static func lastDot(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Int? {
        var p = hi - 1
        let stop = max(lo, hi - 7)
        while p >= stop {
            if b[p] == 0x2E { return p }
            p -= 1
        }
        return nil
    }

    /// Drops a trailing ".part01" / ".part1" in front of a stripped archive extension.
    private static func dropPartSuffix(_ b: [UInt8], _ hi: inout Int) {
        var p = hi - 1
        var digits = 0
        while p >= 0, b[p] >= 0x30, b[p] <= 0x39 { p -= 1; digits += 1 }
        guard digits > 0, p >= 4 else { return }
        let word = String(decoding: b[(p - 3)...p], as: UTF8.self).lowercased()
        if word == "part", p - 4 >= 0, b[p - 4] == 0x2E || b[p - 4] == 0x20 { hi = p - 4 }
    }

    private static func hasPrefix(_ b: [UInt8], _ lo: Int, _ hi: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard hi - lo >= u.count else { return false }
        for i in 0..<u.count {
            var c = b[lo + i]
            if c >= 65 && c <= 90 { c += 32 }
            if c != u[i] { return false }
        }
        return true
    }

    private static func hasSuffixCI(_ b: [UInt8], _ lo: Int, _ hi: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard hi - lo > u.count else { return false }
        for i in 0..<u.count {
            var c = b[hi - u.count + i]
            if c >= 65 && c <= 90 { c += 32 }
            if c != u[i] { return false }
        }
        return true
    }

    private static func bracketOpen(_ b: [UInt8], _ lo: Int, _ hi: Int) -> (UInt8, Int) {
        let c = b[lo]
        if c == 0x5B || c == 0x28 || c == 0x7B { return (c, 1) }
        if c == 0xE3, lo + 2 < hi, b[lo + 1] == 0x80, b[lo + 2] == 0x90 { return (0xE3, 3) }
        return (0, 0)
    }

    private static func isSiteLike(_ lower: String) -> Bool {
        if lower.contains("www.") { return true }
        for suf in [".com", ".org", ".net", ".info", ".to", ".cc", ".io", ".tv", ".me", ".ws", ".ru", ".se", ".pw"] where lower.hasSuffix(suf) {
            return true
        }
        return false
    }

    /// A leading bracket that is a quality tag or year rather than a release group.
    private static func prefixGroupRejected(_ lower: String) -> Bool {
        if lower.isEmpty { return true }
        var sawLetter = false
        var allMarkers = true
        var piece = ""
        func flush() {
            if piece.isEmpty { return }
            if piece.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                // digits: year / number
            } else if Vocabulary.words[piece] != nil {
                // quality word
            } else {
                allMarkers = false
            }
            piece = ""
        }
        for ch in lower.unicodeScalars {
            if ch == " " || ch == "." || ch == "_" || ch == "-" { flush(); continue }
            if ch.properties.isAlphabetic { sawLetter = true }
            piece.unicodeScalars.append(ch)
        }
        flush()
        if !sawLetter { return true }
        return allMarkers
    }
}

extension String {
    fileprivate func trimmingSpaces() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " { s.removeFirst() }
        while let l = s.last, l == " " { s.removeLast() }
        return String(s)
    }
}

// MARK: - Title rendering and group detection

extension Scanner {
    func isSingleLetter(_ k: Int) -> Bool {
        let t = toks[k]
        return t.len == 1 && ((b[t.s] >= 65 && b[t.s] <= 90) || (b[t.s] >= 97 && b[t.s] <= 122))
    }

    func isAllDigits(_ k: Int) -> Bool { toks[k].n >= 0 }

    func gapIsDot(_ k: Int) -> Bool { // gap between k-1 and k
        k >= 1 && toks[k].s - toks[k - 1].e == 1 && b[toks[k - 1].e] == 0x2E
    }

    /// Re-assemble tokens `from..<to` into display text: dots/underscores become spaces, acronym
    /// dots (S.H.I.E.L.D.), number dots (11.22.63), dashes (Spider-Man) and punctuation are kept.
    func render(_ from: Int, _ to: Int) -> String {
        guard from < to, from >= 0, to <= toks.count else { return "" }
        var out: [UInt8] = []
        out.reserveCapacity(toks[to - 1].e - toks[from].s)
        for k in from..<to {
            if k > from {
                if gapIsDot(k) {
                    let prevSingle = isSingleLetter(k - 1)
                    let nextSingle = isSingleLetter(k)
                    if prevSingle && nextSingle {
                        out.append(0x2E)
                    } else if prevSingle, k - 2 >= from, isSingleLetter(k - 2), gapIsDot(k - 1) {
                        out.append(0x2E); out.append(0x20)
                    } else if isAllDigits(k - 1) && isAllDigits(k) {
                        out.append(0x2E)
                    } else {
                        out.append(0x20)
                    }
                } else {
                    var p = toks[k - 1].e
                    let q = toks[k].s
                    while p < q {
                        let c = b[p]
                        if c == 0x2E || c == 0x5F || c == 0x20 || c == 0x09 {
                            if out.last != 0x20 { out.append(0x20) }
                        } else {
                            out.append(c)
                        }
                        p += 1
                    }
                }
            }
            out.append(contentsOf: b[toks[k].s..<toks[k].e])
        }
        // trim
        func isTrim(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x28 || c == 0x5B || c == 0x7B || c == 0x3A || c == 0x2C || c == 0x3B
        }
        while let l = out.last, isTrim(l), !(l == 0x2E && out.count > 2 && out[out.count - 2] != 0x20 && isSingleLetterByte(out, out.count - 2)) { out.removeLast() }
        var start = 0
        while start < out.count, isTrim(out[start]) || out[start] == 0x29 || out[start] == 0x5D { start += 1 }
        if start > 0 { out.removeFirst(start) }
        var opens = 0, closes = 0, sOpens = 0, sCloses = 0
        for c in out {
            switch c {
            case 0x28: opens += 1
            case 0x29: closes += 1
            case 0x5B: sOpens += 1
            case 0x5D: sCloses += 1
            default: break
            }
        }
        if opens > closes { out.append(0x29) }
        if sOpens > sCloses { out.append(0x5D) }
        return String(decoding: out, as: UTF8.self)
    }

    private func isSingleLetterByte(_ out: [UInt8], _ idx: Int) -> Bool {
        // letter at idx preceded by '.' (acronym tail such as "S.W.A.T.")
        guard idx >= 1 else { return false }
        let c = out[idx]
        guard (c >= 65 && c <= 90) || (c >= 97 && c <= 122) else { return false }
        return out[idx - 1] == 0x2E
    }

    /// Release group from the trailing run of unrecognised tokens: "...x264-GROUP", "...D-Z0N3", "[YTS.MX]".
    mutating func findTailGroup() -> String? {
        let n = toks.count
        var k = n
        while k > titleEnd && !toks[k - 1].used { k -= 1 }
        guard k < n else { return nil }
        var qualityBefore = false
        for j in titleEnd..<k where toks[j].q { qualityBefore = true; break }
        var gs = -1
        for j in k..<n where toks[j].hasDash && !(toks[j].run & Run.bracket != 0 && toks[j].run & (Run.ws | Run.dot) == 0 && false) {
            gs = j
            break
        }
        if gs >= 0 && qualityBefore {
            let g = String(decoding: b[toks[gs].s..<toks[n - 1].e], as: UTF8.self)
            for j in gs..<n { toks[j].used = true }
            return g
        }
        if gs < 0, qualityBefore, toks[k].run & Run.open != 0, k > titleEnd {
            // trailing bracketed tag: "... [Group]"
            let g = String(decoding: b[toks[k].s..<toks[n - 1].e], as: UTF8.self)
            for j in k..<n { toks[j].used = true }
            return g
        }
        return nil
    }
}
