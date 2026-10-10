// Single-pass token scanner behind `ReleaseParser`. Hand-rolled on UTF-8 bytes (no regex engine):
// tokenizes once, finds where the title ends, then classifies the remaining tokens.

enum Run {
    static let dash: UInt8 = 1
    static let open: UInt8 = 2
    static let close: UInt8 = 4
    static let ws: UInt8 = 8
    static let dot: UInt8 = 16
    static let punct: UInt8 = 32
    static let bracket: UInt8 = open | close
}

struct Tok {
    var s: Int
    var e: Int
    var run: UInt8          // separator classes found between the previous token and this one
    var n: Int              // numeric value when the token is all ASCII digits (<= 9 of them), else -1
    var w: Word?
    var l: String           // ASCII lower-cased text
    var used = false
    var q = false           // consumed as a quality attribute

    var len: Int { e - s }
    var tightDash: Bool { run == Run.dash }
    var hasDash: Bool { run & Run.dash != 0 }
    var spacedDash: Bool { run & Run.dash != 0 && run & (Run.ws | Run.dot) != 0 }
    var bracketed: Bool { run & Run.bracket != 0 }
    var plainGap: Bool { run & (Run.dash | Run.bracket) == 0 }
}

struct EpMatch {
    var count = 1
    var seasons: [Int] = []
    var eps: [Int] = []
    var abs: [Int] = []
    var date: AirDate?
    var version = 1
}

struct ScanResult {
    var r = ParsedRelease()
    var titleEnd = 0
}

struct Scanner {
    let b: [UInt8]
    let lb: [UInt8]
    var lo: Int
    var hi: Int
    var toks: [Tok] = []
    var tailRun: UInt8 = 0
    var hasPrefixGroup = false
    var lenient = false

    // accumulated state
    var seasons: [Int] = []
    var episodes: [Int] = []
    var absolute: [Int] = []
    var airDate: AirDate?
    var year: Int?
    var yearIdx = -1
    var haveSE = false
    var epEnd = -1               // token index just past the episode/date marker
    var resolution: Resolution?
    var resWeak = false
    var source: Source?
    var sourceStrong = false
    var videoCodec: VideoCodec?
    var hdr: [HDRFormat] = []
    var bitDepth: Int?
    var audio: [AudioCodec] = []
    var channels: String?
    var languages: [Language] = []
    var editions: [Edition] = []
    var service: String?
    var flags: Set<ReleaseFlag> = []
    var version = 1
    var crc: String?
    var group: String?
    var special = false
    var completePhrase = false
    var completeWord = false
    var sawQuality = false
    var sawAudio = false
    var hasYearLike = false
    var titleEnd = 0

    init(bytes: [UInt8], lo: Int, hi: Int, hasPrefixGroup: Bool, lenient: Bool) {
        self.b = bytes
        var l = bytes
        for i in 0..<l.count where l[i] >= 65 && l[i] <= 90 { l[i] += 32 }
        self.lb = l
        self.lo = lo
        self.hi = hi
        self.hasPrefixGroup = hasPrefixGroup
        self.lenient = lenient
        toks.reserveCapacity(24)
    }

    // MARK: Tokenizer

    @inline(__always)
    private func asciiSep(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x20, 0x09, 0x5F, 0x2C, 0x2F, 0x5C: return Run.ws
        case 0x2E: return Run.dot
        case 0x2D, 0x7E: return Run.dash
        case 0x5B, 0x28, 0x7B: return Run.open
        case 0x5D, 0x29, 0x7D: return Run.close
        case 0x3A, 0x3B, 0x21, 0x3F, 0x22, 0x7C, 0x2A: return Run.punct
        default: return 0
        }
    }

    /// Separator class and byte length at `p`, or (0, 0) when `p` starts a token character.
    @inline(__always)
    private func sepAt(_ p: Int) -> (UInt8, Int) {
        let c = b[p]
        if c < 0x80 {
            let s = asciiSep(c)
            return s == 0 ? (0, 0) : (s, 1)
        }
        if c == 0xE2, p + 2 < hi, b[p + 1] == 0x80, b[p + 2] >= 0x90, b[p + 2] <= 0x95 { return (Run.dash, 3) }
        if c == 0xE3, p + 2 < hi, b[p + 1] == 0x80 {
            switch b[p + 2] {
            case 0x90, 0x8C, 0x8E: return (Run.open, 3)
            case 0x91, 0x8D, 0x8F: return (Run.close, 3)
            default: break
            }
        }
        if c == 0xEF, p + 2 < hi, b[p + 1] == 0xBC {
            if b[p + 2] == 0xBB { return (Run.open, 3) }
            if b[p + 2] == 0xBD { return (Run.close, 3) }
        }
        return (0, 0)
    }

    mutating func tokenize() {
        var p = lo
        var run: UInt8 = 0
        while p < hi {
            let (bits, len) = sepAt(p)
            if bits != 0 {
                run |= bits
                p += len
                continue
            }
            let s = p
            var allDigits = true
            var n = 0
            while p < hi {
                let c = b[p]
                if c < 0x80 {
                    if asciiSep(c) != 0 { break }
                } else if sepAt(p).1 != 0 {
                    break
                }
                if c >= 0x30 && c <= 0x39 {
                    if n < 100_000_000 { n = n * 10 + Int(c - 0x30) }
                } else {
                    allDigits = false
                }
                p += 1
            }
            let tlen = p - s
            let l = String(decoding: lb[s..<p], as: UTF8.self)
            toks.append(Tok(s: s, e: p, run: run, n: allDigits && tlen <= 9 ? n : -1, w: Vocabulary.words[l], l: l))
            run = 0
        }
        tailRun = run
    }

    // MARK: Low-level helpers

    @inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Parse digits in lb[p..<q]; returns nil if not all digits or empty/too long.
    func digits(_ p: Int, _ q: Int, max: Int = 9) -> Int? {
        if q <= p || q - p > max { return nil }
        var v = 0
        for i in p..<q {
            let c = lb[i]
            if !isDigit(c) { return nil }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }

    func isYearValue(_ v: Int) -> Bool { v >= 1900 && v <= 2035 }

    func isYear(_ i: Int) -> Bool {
        let t = toks[i]
        return t.len == 4 && t.n >= 0 && isYearValue(t.n)
    }

    /// `s01`, `s01e02`, `s01e02e03` -> (season, episodes)
    func parseSE(_ t: Tok) -> (season: Int, eps: [Int])? {
        guard t.len >= 2, t.len <= 20, lb[t.s] == 0x73 else { return nil }
        var p = t.s + 1
        let ds = p
        while p < t.e && isDigit(lb[p]) { p += 1 }
        guard p > ds, p - ds <= 4, let season = digits(ds, p) else { return nil }
        var eps: [Int] = []
        while p < t.e {
            guard lb[p] == 0x65 else { return nil }
            p += 1
            let es = p
            while p < t.e && isDigit(lb[p]) { p += 1 }
            guard p > es, p - es <= 4, let ep = digits(es, p) else { return nil }
            eps.append(ep)
        }
        return (season, eps)
    }

    /// `e05`, `ep05`, `e05e06` -> episodes
    func parseE(_ t: Tok) -> [Int]? {
        guard t.len >= 2, t.len <= 20, lb[t.s] == 0x65 else { return nil }
        var p = t.s
        var eps: [Int] = []
        while p < t.e {
            guard lb[p] == 0x65 else { return nil }
            p += 1
            if p < t.e, lb[p] == 0x70, eps.isEmpty { p += 1 }
            let es = p
            while p < t.e && isDigit(lb[p]) { p += 1 }
            guard p > es, p - es <= 4, let ep = digits(es, p) else { return nil }
            eps.append(ep)
        }
        return eps
    }

    /// `1x01`, `01x01`, `1x01x02` -> (season, episodes)
    func parseNxM(_ t: Tok) -> (season: Int, eps: [Int])? {
        guard t.len >= 3, t.len <= 16, isDigit(lb[t.s]) else { return nil }
        var p = t.s
        while p < t.e && isDigit(lb[p]) { p += 1 }
        guard p - t.s <= 2, p < t.e, lb[p] == 0x78, let season = digits(t.s, p) else { return nil }
        var eps: [Int] = []
        while p < t.e {
            guard lb[p] == 0x78 else { return nil }
            p += 1
            let es = p
            while p < t.e && isDigit(lb[p]) { p += 1 }
            guard p > es, p - es <= 3, let ep = digits(es, p) else { return nil }
            eps.append(ep)
        }
        return (season, eps)
    }

    /// `1920x1080` style resolution
    func wxhResolution(_ t: Tok) -> Resolution? {
        guard t.len >= 7, t.len <= 9 else { return nil }
        var p = t.s
        while p < t.e && isDigit(lb[p]) { p += 1 }
        guard p - t.s >= 3, p < t.e, lb[p] == 0x78 else { return nil }
        guard let h = digits(p + 1, t.e) else { return nil }
        switch h {
        case 480: return .p480
        case 576: return .p576
        case 720: return .p720
        case 1080: return .p1080
        case 2160: return .p2160
        default: return nil
        }
    }

    /// `05` or `05v2` -> (value, version)
    func parseAbs(_ t: Tok) -> (Int, Int)? {
        guard t.len >= 1, t.len <= 6 else { return nil }
        var p = t.s
        while p < t.e && isDigit(lb[p]) { p += 1 }
        let nd = p - t.s
        guard nd >= 1, nd <= 4, let v = digits(t.s, p) else { return nil }
        if p == t.e { return (v, 1) }
        guard lb[p] == 0x76, t.e - p == 2, isDigit(lb[p + 1]) else { return nil }
        return (v, Int(lb[p + 1] - 0x30))
    }

    func ordinal(_ t: Tok) -> Int? {
        // 12th, 1st, 2nd, 3rd
        guard t.len >= 3, t.len <= 4 else { return nil }
        var p = t.s
        while p < t.e && isDigit(lb[p]) { p += 1 }
        guard p > t.s, t.e - p == 2, let v = digits(t.s, p), v >= 1, v <= 31 else { return nil }
        let suf = String(decoding: lb[p..<t.e], as: UTF8.self)
        return ["st", "nd", "rd", "th"].contains(suf) ? v : nil
    }

    func dayValue(_ t: Tok) -> Int? {
        if t.n >= 1 && t.n <= 31 && t.len <= 2 { return t.n }
        return ordinal(t)
    }

    func validDate(_ y: Int, _ m: Int, _ d: Int) -> AirDate? {
        guard isYearValue(y), m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        return AirDate(year: y, month: m, day: d)
    }

    func expand(_ lo: Int, _ hi: Int) -> [Int] {
        if hi <= lo || hi - lo > 300 { return [hi] }
        return Array((lo + 1)...hi)
    }

    /// Strong quality words that can terminate a title (no episode logic).
    func isStrongWord(_ i: Int) -> Bool {
        guard i < toks.count else { return false }
        let t = toks[i]
        if let w = t.w {
            switch w {
            case .res(_, let weak): return !weak
            case .codec: return true
            case .src(_, let strong): return strong
            default: break
            }
        }
        if wxhResolution(t) != nil { return true }
        let n = toks.count
        switch t.l {
        case "web": return i + 1 < n && (toks[i + 1].l == "dl" || toks[i + 1].l == "rip")
        case "blu": return i + 1 < n && toks[i + 1].l == "ray"
        case "hd": return i + 1 < n && toks[i + 1].l == "tv"
        case "h": return i + 1 < n && (toks[i + 1].l == "264" || toks[i + 1].l == "265")
        default: return false
        }
    }

    // MARK: Episode recognizers

    func matchEpisode(_ i: Int) -> EpMatch? {
        let t = toks[i]
        if t.n >= 0 { return matchNumeric(i) }
        if let se = parseSE(t) { return matchSE(i, season: se.season, eps: se.eps) }
        if let nm = parseNxM(t) { return matchNxM(i, season: nm.season, eps: nm.eps) }
        let n = toks.count
        let l = t.l
        if Vocabulary.seasonWords.contains(l) {
            if l == "series" && i == 0 { return nil }
            guard i + 1 < n, toks[i + 1].n >= 0, toks[i + 1].len <= 3, toks[i + 1].plainGap else { return nil }
            if l == "series" && toks[i + 1].n > 40 { return nil }
            var m = EpMatch()
            m.seasons = [toks[i + 1].n]
            var j = i + 2
            while j < n, toks[j].n >= 0, toks[j].len <= 3, toks[j].hasDash, !toks[j].bracketed, toks[j].n > m.seasons.last!,
                  toks[j].tightDash || lb[toks[j].s] != 0x30 {
                m.seasons += expand(m.seasons.last!, toks[j].n)
                j += 1
            }
            if j < n, toks[j].spacedDash, let a = matchDashedAbs(j) {
                // "Title Season 2 - 05"
                m.eps = a.abs
                m.version = a.version
                m.count = j + a.count - i
                return m
            }
            // "Season 1 Episode 3" / "Season 1 E03"
            if j < n, toks[j].plainGap || toks[j].tightDash || toks[j].spacedDash {
                if Vocabulary.episodeWords.contains(toks[j].l), j + 1 < n, toks[j + 1].n >= 0, toks[j + 1].len <= 4 {
                    m.eps = [toks[j + 1].n]
                    j += 2
                    extendEpisodes(&m, &j)
                } else if let es = parseE(toks[j]) {
                    m.eps = es
                    j += 1
                    extendEpisodes(&m, &j)
                }
            }
            m.count = j - i
            return m
        }
        if Vocabulary.episodeWords.contains(l) {
            guard i + 1 < n, toks[i + 1].n >= 0, toks[i + 1].len <= 4, !toks[i + 1].bracketed else { return nil }
            var m = EpMatch()
            m.eps = [toks[i + 1].n]
            var j = i + 2
            extendEpisodes(&m, &j)
            m.count = j - i
            return m
        }
        if let es = parseE(t) {
            var m = EpMatch()
            m.eps = es
            var j = i + 1
            extendEpisodes(&m, &j)
            m.count = j - i
            return m
        }
        if t.spacedDash, let a = matchDashedAbs(i) {
            var m = EpMatch(); m.abs = a.abs; m.version = a.version; m.count = a.count; return m
        }
        if let md = matchMonthDate(i) { return md }
        return nil
    }

    func matchSE(_ i: Int, season: Int, eps: [Int]) -> EpMatch {
        var m = EpMatch()
        m.seasons = [season]
        m.eps = eps
        var j = i + 1
        let n = toks.count
        if eps.isEmpty {
            var last = season
            while j < n {
                let u = toks[j]
                if u.bracketed { break }
                if let se2 = parseSE(u), se2.eps.isEmpty {
                    if u.hasDash { m.seasons += expand(last, se2.season) } else { m.seasons.append(se2.season) }
                    last = se2.season
                    j += 1
                    continue
                }
                if u.tightDash, u.n >= 0, u.len <= 2, u.n > last, u.n < 100 {
                    m.seasons += expand(last, u.n)
                    last = u.n
                    j += 1
                    continue
                }
                break
            }
            if j < n, m.seasons.count == 1, !toks[j].bracketed {
                let u = toks[j]
                if !u.hasDash, let es = parseE(u) {
                    m.eps = es
                    j += 1
                } else if !u.hasDash, Vocabulary.episodeWords.contains(u.l), j + 1 < n, toks[j + 1].n >= 0, toks[j + 1].len <= 4 {
                    m.eps = [toks[j + 1].n]
                    j += 2
                } else if u.spacedDash, let a = matchDashedAbs(j) {
                    // "Title S2 - 05"
                    m.eps = a.abs
                    m.version = a.version
                    j += a.count
                    m.count = j - i
                    return m
                }
            }
        }
        if !m.eps.isEmpty { extendEpisodes(&m, &j) }
        m.count = j - i
        return m
    }

    func matchNxM(_ i: Int, season: Int, eps: [Int]) -> EpMatch {
        var m = EpMatch()
        m.seasons = [season]
        m.eps = eps
        var j = i + 1
        extendEpisodes(&m, &j)
        m.count = j - i
        return m
    }

    /// Extend an episode list over following `E03`, `-E05`, `-05`, `-1x05`, `-S01E05` tokens.
    func extendEpisodes(_ m: inout EpMatch, _ j: inout Int) {
        let n = toks.count
        while j < n {
            let u = toks[j]
            if u.bracketed { break }
            let last = m.eps.last ?? 0
            if let es = parseE(u) {
                if u.hasDash, let f = es.first, f > last {
                    m.eps += expand(last, f)
                    m.eps += es.dropFirst()
                } else if u.hasDash || u.spacedDash {
                    break
                } else {
                    m.eps += es
                }
                j += 1
                continue
            }
            if u.tightDash {
                if let se2 = parseSE(u), !se2.eps.isEmpty, se2.season == m.seasons.last {
                    if let f = se2.eps.first, f > last { m.eps += expand(last, f); m.eps += se2.eps.dropFirst() } else { m.eps += se2.eps }
                    j += 1
                    continue
                }
                if let nm = parseNxM(u), nm.season == m.seasons.last {
                    if let f = nm.eps.first, f > last { m.eps += expand(last, f); m.eps += nm.eps.dropFirst() } else { m.eps += nm.eps }
                    j += 1
                    continue
                }
                if u.n >= 0, u.len <= 3, u.n > last, u.n - last <= 60, u.n != 480, u.n != 576, u.n != 720 {
                    m.eps += expand(last, u.n)
                    j += 1
                    continue
                }
            }
            break
        }
    }

    func matchMonthDate(_ i: Int) -> EpMatch? {
        let n = toks.count
        guard i + 2 < n else { return nil }
        let t = toks[i]
        // "Mon dd yyyy"
        if let mo = Vocabulary.months[t.l], let d = dayValue(toks[i + 1]), isYear(i + 2),
           toks[i + 1].plainGap || toks[i + 1].tightDash, toks[i + 2].plainGap || toks[i + 2].tightDash,
           let date = validDate(toks[i + 2].n, mo, d) {
            var m = EpMatch(); m.date = date; m.count = 3; return m
        }
        // "dd[th] Mon yyyy" with ordinal day
        if let d = ordinal(t), let mo = Vocabulary.months[toks[i + 1].l], isYear(i + 2),
           let date = validDate(toks[i + 2].n, mo, d) {
            var m = EpMatch(); m.date = date; m.count = 3; return m
        }
        return nil
    }

    func matchDate(_ i: Int) -> EpMatch? {
        let n = toks.count
        let t = toks[i]
        if t.len == 8, t.n >= 0 {
            let y = t.n / 10000, mo = (t.n / 100) % 100, d = t.n % 100
            if let date = validDate(y, mo, d) { var m = EpMatch(); m.date = date; return m }
            return nil
        }
        guard i + 2 < n else { return nil }
        let t1 = toks[i + 1], t2 = toks[i + 2]
        if !(t1.plainGap || t1.tightDash) || !(t2.plainGap || t2.tightDash) { return nil }
        if isYear(i) {
            if t1.n >= 0, t2.n >= 0, t1.len <= 2, t2.len <= 2, t1.len == 2 || t2.len == 2,
               let date = validDate(t.n, t1.n, t2.n) {
                var m = EpMatch(); m.date = date; m.count = 3; return m
            }
            if let mo = Vocabulary.months[t1.l], let d = dayValue(t2), let date = validDate(t.n, mo, d) {
                var m = EpMatch(); m.date = date; m.count = 3; return m
            }
            return nil
        }
        if t.len <= 2, t.n >= 0, isYear(i + 2) {
            guard t1.n >= 0, t1.len <= 2, t.len == 2 || t1.len == 2 else {
                // "12 May 2019"
                if let mo = Vocabulary.months[t1.l], t.n >= 1, t.n <= 31, let date = validDate(t2.n, mo, t.n) {
                    var m = EpMatch(); m.date = date; m.count = 3; return m
                }
                return nil
            }
            let a = t.n, c = t1.n
            if a > 12, let date = validDate(t2.n, c, a) { var m = EpMatch(); m.date = date; m.count = 3; return m }
            if let date = validDate(t2.n, a, c) { var m = EpMatch(); m.date = date; m.count = 3; return m }
            if let date = validDate(t2.n, c, a) { var m = EpMatch(); m.date = date; m.count = 3; return m }
        }
        return nil
    }

    /// " - 05", " - 05v2", " - 01-12" (anime absolute numbering)
    func matchDashedAbs(_ i: Int) -> (abs: [Int], version: Int, count: Int)? {
        let n = toks.count
        guard i >= 1 else { return nil }
        let t = toks[i]
        guard t.spacedDash, !t.bracketed || t.run & Run.open == 0 else { return nil }
        guard let (v, ver) = parseAbs(t) else { return nil }
        if t.len == 4 && t.n >= 0 && isYearValue(v) { return nil }
        if t.n >= 0 && (v == 480 || v == 576 || v == 720 || v == 1080 || v == 2160) { return nil }
        var vals = [v]
        var count = 1
        if i + 1 < n, toks[i + 1].tightDash, toks[i + 1].n >= 0, toks[i + 1].len <= 4, toks[i + 1].n > v {
            vals += expand(v, toks[i + 1].n)
            count = 2
        }
        let nx = i + count
        if nx < n {
            let u = toks[nx]
            let ok = hasPrefixGroup || u.bracketed || u.hasDash || isStrongWord(nx) || u.w != nil
            if !ok { return nil }
        }
        return (vals, ver, count)
    }

    func matchNumeric(_ i: Int) -> EpMatch? {
        let t = toks[i]
        let n = toks.count
        if let d = matchDate(i) { return d }
        if let a = matchDashedAbs(i) {
            var m = EpMatch(); m.abs = a.abs; m.version = a.version; m.count = a.count; return m
        }
        if hasPrefixGroup && i >= 1 && !(t.len == 4 && isYearValue(t.n)) {
            // "[Group] Title (01-26)" / "[Group] Title [01-26]"
            if t.run & Run.open != 0, t.len <= 4, i + 1 < n, toks[i + 1].tightDash, toks[i + 1].n > t.n, toks[i + 1].len <= 4,
               toks[i + 1].n >= 0, i + 2 >= n || toks[i + 2].run & Run.close != 0 || toks[i + 1].run & Run.close != 0 {
                var m = EpMatch(); m.abs = expand(t.n, toks[i + 1].n); m.abs.insert(t.n, at: 0); m.count = 2; return m
            }
            // "[Group] Title 05 [1080p]"
            if t.plainGap, t.len <= 4, !(t.n >= 0 && [480, 576, 720, 1080, 2160].contains(t.n)), toks[i - 1].l != "part",
               !Vocabulary.seasonWords.contains(toks[i - 1].l), !Vocabulary.episodeWords.contains(toks[i - 1].l),
               i + 1 < n, toks[i + 1].run & Run.open != 0, toks[i + 1].run & Run.dash == 0 {
                var m = EpMatch(); m.abs = [t.n]; return m
            }
        }
        // Bare 3/4-digit SSEE ("Show.Name.101.720p.HDTV")
        if i >= 1, !hasYearLike, (t.len == 3 || t.len == 4), t.plainGap, t.run & Run.bracket == 0 {
            let s = t.n / 100, e = t.n % 100
            if t.n != 480, t.n != 576, t.n != 720, s >= 1, s <= (t.len == 3 ? 9 : 18), e >= 1, e <= 40, !(t.len == 4 && t.n >= 1900),
               i + 1 < n, isStrongWord(i + 1) {
                var m = EpMatch(); m.seasons = [s]; m.eps = [e]; return m
            }
        }
        // Leading episode number: "03 - Title", or any "03 Title" in file context
        if lenient, i >= 1, t.len <= 3, t.n >= 1, !hasYearLike, i == n - 1 || isStrongWord(i + 1) {
            var m = EpMatch(); m.eps = [t.n]; return m
        }
        if i == 0, !hasPrefixGroup, t.len <= 4, !(t.len == 4 && isYearValue(t.n)) {
            if lenient {
                var m = EpMatch(); m.eps = [t.n]; return m
            }
            if n > 1, toks[1].spacedDash {
                var m = EpMatch(); m.eps = [t.n]; return m
            }
        }
        return nil
    }

    // MARK: Phase one: where does the title end?

    func isExtraMarker(_ i: Int) -> Bool {
        guard i >= 1 else { return false }
        let l = toks[i].l
        return l.hasPrefix("ncop") || l.hasPrefix("nced")
    }

    /// Bonus-short markers terminate the title: "Black Lagoon - Omake 02" is the omake
    /// batch, not a show called "Black Lagoon Omake". Only "omake" is this unambiguous;
    /// "special(s)"/"ova" stay in the title (see `WantedItem.match`).
    func isOmakeMarker(_ i: Int) -> Bool {
        guard i > 0, i < toks.count else { return false }
        let l = toks[i].l
        return l == "omake" || l == "omakes"
    }

    func completePhraseAt(_ i: Int) -> Bool {
        toks[i].l == "complete" && i + 1 < toks.count && Vocabulary.completeFollowers.contains(toks[i + 1].l)
    }

    func isSoftAnchor(_ i: Int) -> Bool {
        guard i > 0, let w = toks[i].w else { return false }
        switch w {
        case .proper, .repack, .rerip, .hdr, .bits, .audio: return true
        case .src: return true
        case .service(_, let amb): return !amb
        case .lang(let l, _): return l == .multi
        default: return false
        }
    }

    mutating func computeTitleEnd() {
        let n = toks.count
        hasYearLike = false
        for i in 0..<n where isYear(i) { hasYearLike = true; break }
        var hard = n
        for i in 0..<n {
            if isStrongWord(i) || completePhraseAt(i) || isExtraMarker(i) || isOmakeMarker(i) || matchEpisode(i) != nil { hard = i; break }
        }
        // Year: last 4-digit year before the first hard marker (not at index 0).
        var cand = -1
        var i = 0
        while i < min(hard, n) {
            if isYear(i) { cand = i }
            i += 1
        }
        if cand == 0 { cand = -1 }
        if cand > 0 { yearIdx = cand }
        var end = hard
        if cand > 0 { end = min(end, cand) }
        if hard == n && cand < 0 {
            for k in 1..<max(n, 1) where isSoftAnchor(k) { end = k; break }
        }
        if hasPrefixGroup {
            for k in 1..<max(n, 1) where k < end && toks[k].run & Run.open != 0 {
                let t = toks[k]
                if t.w != nil || t.n >= 0 || t.l == "dual" || t.l == "multi" || t.l == "complete" { end = k; break }
            }
        }
        // Weak quality words opening a bracket ("[BD 1080p]") are not part of the title.
        while end > 1, toks[end - 1].run & Run.open != 0, let w = toks[end - 1].w {
            if case .src(_, strong: false) = w { end -= 1 } else if case .res(_, weak: true) = w { end -= 1 } else { break }
        }
        if end < n, end > 1, toks[end].l == "complete", toks[end - 1].l == "the" { end -= 1 }
        titleEnd = end
    }

    // MARK: Phase two: classify everything after the title

    mutating func setSource(_ s: Source, strong: Bool) {
        sawQuality = true
        if s == .remux { source = .remux; sourceStrong = true; return }
        if source == nil || (!sourceStrong && strong) { source = s; sourceStrong = strong }
    }

    mutating func addAudio(_ a: AudioCodec) {
        sawQuality = true
        sawAudio = true
        if !audio.contains(a) { audio.append(a) }
    }

    mutating func addLang(_ l: Language) {
        if !languages.contains(l) { languages.append(l) }
    }

    mutating func addHDR(_ h: HDRFormat) {
        sawQuality = true
        if !hdr.contains(h) { hdr.append(h) }
    }

    mutating func setChannels(_ c: String) {
        if channels == nil { channels = c }
    }

    func isQualityNeighbor(_ k: Int) -> Bool {
        guard k >= 0, k < toks.count else { return false }
        if toks[k].q { return true }
        guard let w = toks[k].w else { return false }
        switch w {
        case .noise, .special, .edition, .flag, .proper, .repack, .rerip, .real: return false
        case .lang: return true
        default: return true
        }
    }

    /// Soft words (languages, editions...) are only trusted when they cannot be part of an episode title.
    func softOK(_ i: Int) -> Bool {
        !haveSE && airDate == nil && absolute.isEmpty || sawQuality || isQualityNeighbor(i - 1) || isQualityNeighbor(i + 1)
    }

    mutating func mark(_ i: Int, _ count: Int, quality: Bool = true) {
        for k in i..<min(i + count, toks.count) {
            toks[k].used = true
            if quality { toks[k].q = true }
        }
    }

    mutating func applyEpisode(_ m: EpMatch, at i: Int) -> Bool {
        if m.date != nil {
            if airDate != nil || haveSE || !absolute.isEmpty { return false }
            airDate = m.date
        } else if !m.abs.isEmpty {
            if !absolute.isEmpty || haveSE || airDate != nil { return false }
            absolute = m.abs
            if m.version > 1 { version = max(version, m.version) }
        } else {
            if haveSE || airDate != nil || !absolute.isEmpty { return false }
            seasons = m.seasons
            if m.version > 1 { version = max(version, m.version) }
            episodes = m.eps
            haveSE = true
        }
        mark(i, m.count, quality: false)
        epEnd = i + m.count
        return true
    }

    mutating func classifyAll() {
        let n = toks.count
        for k in 0..<min(titleEnd, n) { toks[k].used = true }
        var i = titleEnd
        while i < n {
            if i == yearIdx && year == nil {
                year = toks[i].n
                mark(i, 1, quality: false)
                i += 1
                continue
            }
            if toks[i].used { i += 1; continue }
            if let m = matchEpisode(i) {
                if applyEpisode(m, at: i) { i += m.count; continue }
            }
            let c = classify(i)
            i += max(c, 1)
        }
        if year == nil {
            // A parenthesised year after the quality tags: "Title [1080p] (2019)"
            for k in titleEnd..<n where !toks[k].used && isYear(k) && toks[k].run & Run.open != 0 {
                year = toks[k].n
                mark(k, 1, quality: false)
                break
            }
        }
        if lenient && !haveSE && airDate == nil && absolute.isEmpty && episodes.isEmpty {
            // "Show Name 03.mkv": last small number in a pack file
            var k = n - 1
            while k >= 0 {
                if !toks[k].used || k >= titleEnd {
                    if toks[k].n >= 0, toks[k].len <= 3, !toks[k].used, k >= 1 {
                        episodes = [toks[k].n]
                        haveSE = true
                        toks[k].used = true
                        epEnd = k + 1
                        break
                    }
                }
                k -= 1
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    mutating func classify(_ i: Int) -> Int {
        let n = toks.count
        let t = toks[i]
        func L(_ k: Int) -> String { k < n && k >= 0 ? toks[k].l : "" }
        switch t.l {
        case "web":
            if L(i + 1) == "dl" { setSource(.webDL, strong: true); mark(i, 2); return 2 }
            if L(i + 1) == "rip" { setSource(.webRip, strong: true); mark(i, 2); return 2 }
            setSource(.webDL, strong: false); mark(i, 1); return 1
        case "blu":
            if L(i + 1) == "ray" {
                setSource(.bluRay, strong: true)
                var c = 2
                if L(i + 2) == "rip" { c = 3 }
                mark(i, c); return c
            }
        case "hd":
            if L(i + 1) == "tv" { setSource(.hdtv, strong: true); mark(i, 2); return 2 }
            if L(i + 1) == "rip" { setSource(.webRip, strong: true); mark(i, 2); return 2 }
            if L(i + 1) == "dvd" { setSource(.dvd, strong: true); mark(i, 2); return 2 }
            if L(i + 1) == "cam" { setSource(.cam, strong: true); mark(i, 2); return 2 }
            mark(i, 1, quality: false); return 1
        case "dvd":
            if L(i + 1) == "rip" || L(i + 1) == "r" { setSource(.dvd, strong: true); mark(i, 2); return 2 }
        case "bd", "br":
            if L(i + 1) == "rip" { setSource(.bluRay, strong: true); mark(i, 2); return 2 }
            if L(i + 1) == "remux" { setSource(.remux, strong: true); mark(i, 2); return 2 }
        case "uhd":
            if L(i + 1) == "blu" && L(i + 2) == "ray" { setSource(.bluRay, strong: true); setWeakRes(.p2160); mark(i, 3); return 3 }
        case "h":
            if L(i + 1) == "264" { videoCodec = videoCodec ?? .h264; sawQuality = true; mark(i, 2); return 2 }
            if L(i + 1) == "265" { videoCodec = videoCodec ?? .h265; sawQuality = true; mark(i, 2); return 2 }
        case "mpeg":
            if L(i + 1) == "2" { videoCodec = videoCodec ?? .mpeg2; sawQuality = true; mark(i, 2); return 2 }
        case "vc":
            if L(i + 1) == "1" { videoCodec = videoCodec ?? .vc1; sawQuality = true; mark(i, 2); return 2 }
        case "dts":
            sawQuality = true
            let a = L(i + 1)
            if a == "hd" {
                let b2 = L(i + 2)
                if b2 == "ma" { addAudio(.dtsHDMA); mark(i, 3); return 3 }
                if b2 == "hra" { addAudio(.dtsHD); mark(i, 3); return 3 }
                if b2 == "es" { addAudio(.dtsHD); mark(i, 3); return 3 }
                addAudio(.dtsHD); mark(i, 2); return 2
            }
            if a == "ma" { addAudio(.dtsHDMA); mark(i, 2); return 2 }
            if a == "x" { addAudio(.dtsX); mark(i, 2); return 2 }
            if a == "es" { addAudio(.dts); mark(i, 2); return 2 }
            addAudio(.dts); mark(i, 1)
            return 1
        case "e":
            if L(i + 1) == "ac" && L(i + 2) == "3" { addAudio(.eac3); mark(i, 3); return 3 }
        case "ac":
            if L(i + 1) == "3" { addAudio(.ac3); mark(i, 2); return 2 }
        case "dolby":
            let a = L(i + 1)
            if a == "digital" {
                if L(i + 2) == "plus" { addAudio(.eac3); mark(i, 3); return 3 }
                addAudio(.ac3); mark(i, 2); return 2
            }
            if a == "truehd" { addAudio(.trueHD); mark(i, 2); return 2 }
            if a == "atmos" { addAudio(.atmos); mark(i, 2); return 2 }
            if a == "vision" { addHDR(.dolbyVision); mark(i, 2); return 2 }
            mark(i, 1, quality: false); return 1
        case "multi":
            if L(i + 1) == "sub" || L(i + 1) == "subs" || L(i + 1) == "subtitle" || L(i + 1) == "subtitles" {
                flags.insert(.subbed); mark(i, 2, quality: false); return 2
            }
        case "dual":
            if L(i + 1) == "audio" { addLang(.multi); mark(i, 2); return 2 }
        case "director's", "directors", "director":
            if L(i + 1) == "cut" || L(i + 1) == "edition" { editions.appendUnique(.directorsCut); mark(i, 2, quality: false); return 2 }
        case "special":
            if L(i + 1) == "edition" { editions.appendUnique(.specialEdition); mark(i, 2, quality: false); return 2 }
            if L(i + 1) == "features" || L(i + 1) == "feature" { flags.insert(.extra); mark(i, 2, quality: false); return 2 }
        case "ultimate":
            if L(i + 1) == "edition" || L(i + 1) == "cut" { editions.appendUnique(.ultimateEdition); mark(i, 2, quality: false); return 2 }
        case "final":
            if L(i + 1) == "cut" { editions.appendUnique(.finalCut); mark(i, 2, quality: false); return 2 }
        case "rogue":
            if L(i + 1) == "cut" { editions.appendUnique(.rogueCut); mark(i, 2, quality: false); return 2 }
        case "open":
            if L(i + 1) == "matte" { editions.appendUnique(.openMatte); mark(i, 2, quality: false); return 2 }
        case "extended":
            if softOK(i) {
                editions.appendUnique(.extended)
                var c = 1
                let a = L(i + 1)
                if a == "cut" || a == "edition" || a == "version" { c = 2 }
                mark(i, c, quality: false); return c
            }
        case "theatrical":
            if softOK(i) {
                editions.appendUnique(.theatrical)
                var c = 1
                let a = L(i + 1)
                if a == "cut" || a == "edition" || a == "version" { c = 2 }
                mark(i, c, quality: false); return c
            }
        case "complete":
            if completePhraseAt(i) { completePhrase = true; mark(i, 2, quality: false); return 2 }
            completeWord = true; mark(i, 1, quality: false); return 1
        case "omake", "omakes":
            // Bonus shorts are always season-0 content; never part of the title.
            special = true; mark(i, 1, quality: false); return 1
        case "vostfr", "subfrench", "truefrench":
            addLang(.french)
            if t.l != "truefrench" { flags.insert(.subbed) }
            mark(i, 1); return 1
        case "dl":
            break
        case "sample":
            flags.insert(.sample); mark(i, 1, quality: false); return 1
        case "behind":
            if L(i + 1) == "the" && L(i + 2) == "scenes" { flags.insert(.extra); mark(i, 3, quality: false); return 3 }
        case "deleted":
            if L(i + 1) == "scenes" || L(i + 1) == "scene" { flags.insert(.extra); mark(i, 2, quality: false); return 2 }
        case "making":
            if L(i + 1) == "of" { flags.insert(.extra); mark(i, 2, quality: false); return 2 }
        case "gag":
            if L(i + 1) == "reel" { flags.insert(.extra); mark(i, 2, quality: false); return 2 }
        default:
            break
        }
        // Vocabulary words
        if let w = t.w {
            switch w {
            case .res(let r, let weak):
                if weak { setWeakRes(r) } else { resolution = r; resWeak = false }
                sawQuality = true
                mark(i, 1); return 1
            case .src(let s, let strong):
                if !strong && ["ts", "tc", "wp", "scr", "r5", "r6", "vhs", "cam"].contains(t.l) {
                    guard isQualityNeighbor(i - 1) || isQualityNeighbor(i + 1) else { return 0 }
                }
                setSource(s, strong: strong); mark(i, 1); return 1
            case .codec(let c):
                videoCodec = videoCodec ?? c; sawQuality = true; mark(i, 1); return 1
            case .hdr(let h):
                addHDR(h); mark(i, 1); return 1
            case .bits(let v):
                bitDepth = bitDepth ?? v; sawQuality = true; mark(i, 1); return 1
            case .audio(let a):
                addAudio(a)
                var c = 1
                // "DD+" style tokens followed by "5" "1"
                if let ch = channelsAfter(i + 1) { setChannels(ch.0); c += ch.1 }
                mark(i, c); return c
            case .lang(let l, let ctx):
                let next = L(i + 1)
                if ["sub", "subs", "subtitle", "subtitles", "subbed", "dub", "dubbed"].contains(next) {
                    flags.insert(next.hasPrefix("dub") ? .dubbed : .subbed)
                    mark(i, 2, quality: false); return 2
                }
                if ctx { guard isQualityNeighbor(i - 1) || isQualityNeighbor(i + 1) || toks[i - 1 < 0 ? 0 : i - 1].q else { return 0 } }
                else if !softOK(i) { return 0 }
                addLang(l); mark(i, 1); return 1
            case .dl:
                if i > 0, toks[i - 1].q, languages.contains(.german) { addLang(.multi); mark(i, 1); return 1 }
                if softOK(i) { addLang(.multi); mark(i, 1); return 1 }
                return 0
            case .edition(let e):
                guard softOK(i) else { return 0 }
                editions.appendUnique(e)
                var c = 1
                let a = L(i + 1)
                if a == "edition" || a == "cut" || a == "version" { c = 2 }
                mark(i, c, quality: false); return c
            case .service(let s, let amb):
                if amb { guard isQualityNeighbor(i - 1) || isQualityNeighbor(i + 1) else { return 0 } }
                else if !softOK(i) { return 0 }
                service = service ?? s; sawQuality = true; mark(i, 1); return 1
            case .flag(let f):
                if f == .subbed || f == .dubbed || f == .hardcodedSubs || f == .internalRelease {
                    guard softOK(i) else { return 0 }
                }
                flags.insert(f); mark(i, 1, quality: false); return 1
            case .proper:
                flags.insert(.proper); version = max(version, 2); sawQuality = true; mark(i, 1); return 1
            case .repack:
                flags.insert(.repack); version = max(version, 2); sawQuality = true; mark(i, 1); return 1
            case .rerip:
                flags.insert(.repack); version = max(version, 2); sawQuality = true; mark(i, 1); return 1
            case .real:
                flags.insert(.real); mark(i, 1); return 1
            case .special:
                guard softOK(i) else { return 0 }
                special = true; mark(i, 1, quality: false); return 1
            case .noise:
                mark(i, 1, quality: false); return 1
            }
        }
        // Audio token with glued channel digits: ddp5 / aac2 / dd51
        if let (a, ch, c) = audioWithDigits(i) {
            addAudio(a)
            if let ch { setChannels(ch) }
            mark(i, c); return c
        }
        // 1920x1080
        if let r = wxhResolution(t) { resolution = r; resWeak = false; sawQuality = true; mark(i, 1); return 1 }
        // 10 bit
        if t.n == 8 || t.n == 10 || t.n == 12, L(i + 1) == "bit" || L(i + 1) == "bits" {
            bitDepth = bitDepth ?? t.n; sawQuality = true; mark(i, 2); return 2
        }
        // 2ch 6ch 8ch
        if t.len == 3, t.l.hasSuffix("ch"), let d = digits(t.s, t.s + 1) {
            switch d {
            case 2: setChannels("2.0")
            case 6: setChannels("5.1")
            case 8: setChannels("7.1")
            default: return 0
            }
            mark(i, 1); return 1
        }
        // 5.1 / 7.1 / 2.0 / 7.1.4
        if t.n >= 1, t.len == 1, sawAudio || sawQuality, let (ch, c) = channelsAfter(i, includeFirst: true) {
            setChannels(ch); mark(i, c); return c
        }
        // v2 / v3 revision tag
        if t.len == 2, lb[t.s] == 0x76, isDigit(lb[t.s + 1]), toks[i].run & Run.bracket != 0 || sawQuality {
            version = max(version, Int(lb[t.s + 1] - 0x30)); mark(i, 1); return 1
        }
        // CRC32 hash
        if t.len == 8, isHex8(t), t.run & Run.open != 0 || containsLetter(t) {
            crc = String(decoding: b[t.s..<t.e], as: UTF8.self).uppercased()
            mark(i, 1, quality: false); return 1
        }
        return 0
    }

    func containsLetter(_ t: Tok) -> Bool {
        for p in t.s..<t.e where lb[p] >= 0x61 && lb[p] <= 0x7A { return true }
        return false
    }

    func isHex8(_ t: Tok) -> Bool {
        for p in t.s..<t.e {
            let c = lb[p]
            if !(isDigit(c) || (c >= 0x61 && c <= 0x66)) { return false }
        }
        return true
    }

    mutating func setWeakRes(_ r: Resolution) {
        if resolution == nil { resolution = r; resWeak = true }
    }

    /// Reads "5" "1" (dot separated single digits) starting at token `k`. When `includeFirst` is false,
    /// `k` is the token that holds the minor digit pair already attached to the audio word.
    func channelsAfter(_ k: Int, includeFirst: Bool = false) -> (String, Int)? {
        let n = toks.count
        guard k < n else { return nil }
        if includeFirst {
            let a = toks[k]
            guard a.len == 1, a.n >= 1, [1, 2, 5, 6, 7, 8].contains(a.n), k + 1 < n else { return nil }
            let b2 = toks[k + 1]
            guard b2.len == 1, b2.n >= 0, b2.n <= 2, b2.run == Run.dot else { return nil }
            var s = "\(a.n).\(b2.n)"
            var c = 2
            if k + 2 < n, toks[k + 2].len == 1, toks[k + 2].n >= 0, toks[k + 2].run == Run.dot, b2.n == 1 || b2.n == 0 {
                s += ".\(toks[k + 2].n)"
                c = 3
            }
            return (s, c)
        }
        let b2 = toks[k]
        // "DD+" then "5" "1" (separate tokens) or "ddp" then "5.1"
        if b2.len == 1, b2.n >= 1, [1, 2, 5, 6, 7, 8].contains(b2.n), b2.run == Run.dot || b2.run & Run.ws != 0 && b2.run & Run.bracket == 0,
           k + 1 < n, toks[k + 1].len == 1, toks[k + 1].n >= 0, toks[k + 1].n <= 2, toks[k + 1].run == Run.dot {
            return ("\(b2.n).\(toks[k + 1].n)", 2)
        }
        return nil
    }

    /// "ddp5" + "1" / "aac2" + "0" / "dd51"
    func audioWithDigits(_ i: Int) -> (AudioCodec, String?, Int)? {
        let t = toks[i]
        var p = t.s
        while p < t.e && (lb[p] >= 0x61 && lb[p] <= 0x7A || lb[p] == 0x2B) { p += 1 }
        guard p > t.s, p < t.e, t.e - p <= 2, digits(p, t.e) != nil else { return nil }
        let prefix = String(decoding: lb[t.s..<p], as: UTF8.self)
        guard let a = Vocabulary.audioPrefixes[prefix] else { return nil }
        let d = t.e - p
        if d == 2 {
            return (a, "\(lb[p] - 0x30).\(lb[p + 1] - 0x30)", 1)
        }
        let major = Int(lb[p] - 0x30)
        if i + 1 < toks.count, toks[i + 1].len == 1, toks[i + 1].n >= 0, toks[i + 1].n <= 2, toks[i + 1].run == Run.dot {
            return (a, "\(major).\(toks[i + 1].n)", 2)
        }
        return (a, nil, 1)
    }
}

extension Array where Element: Equatable {
    mutating func appendUnique(_ e: Element) {
        if !contains(e) { append(e) }
    }
}
