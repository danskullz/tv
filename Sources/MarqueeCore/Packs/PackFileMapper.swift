import Foundation

/// Maps every file of a (season / multi-season / complete-series) torrent to the episodes it holds.
///
/// Pure and synchronous. Parsing is delegated to ``ReleaseParser``; this type adds the pack-level
/// reasoning: folder context, numbering schemes, sidecars, archives, duplicates and gaps.
public enum PackFileMapper {
    /// - Parameters:
    ///   - files: The torrent's file list in torrent order.
    ///   - series: Expected episodes and numbering for the series.
    ///   - corrections: User corrections keyed by file index. They always win; an empty array means
    ///     "not an episode".
    public static func map(
        files: [PackFile], series: PackSeriesContext, corrections: [Int: [EpisodeRef]] = [:]
    ) -> PackMappingResult {
        var m = Mapper(files: files, series: series, corrections: corrections)
        return m.run()
    }
}

// MARK: - Implementation

private enum FileClass { case video, subtitle, archive, nonMedia, executable }

private let videoExts: Set<String> = [
    "mkv", "mp4", "m4v", "avi", "mov", "wmv", "mpg", "mpeg", "flv", "webm", "m2ts", "ts", "vob", "iso", "ogm",
    "divx", "3gp", "mts", "rmvb", "asf",
]
private let subtitleExts: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup", "smi", "sbv"]
private let executableExts: Set<String> = [
    "exe", "bat", "cmd", "com", "scr", "msi", "lnk", "pif", "vbs", "ps1", "jar", "apk", "dll", "app", "dmg", "sh",
    "js", "wsf", "hta", "cpl",
]
private let languageWords: Set<String> = [
    "english", "eng", "en", "french", "fre", "fra", "fr", "german", "ger", "deu", "de", "spanish", "spa", "es",
    "italian", "ita", "it", "portuguese", "por", "pt", "russian", "rus", "ru", "japanese", "jpn", "ja", "dutch",
    "nld", "nl", "swedish", "swe", "sv", "danish", "dan", "da", "norwegian", "nor", "no", "finnish", "fin", "fi",
    "polish", "pol", "pl", "czech", "ces", "cs", "turkish", "tur", "tr", "arabic", "ara", "ar", "chinese", "chi",
    "zho", "zh", "korean", "kor", "ko", "greek", "ell", "el", "hebrew", "heb", "he", "hindi", "hin", "hi",
    "forced", "sdh", "cc", "full", "signs", "songs", "brazilian", "latin", "und",
]

private struct Mapper {
    let files: [PackFile]
    let series: PackSeriesContext
    let corrections: [Int: [EpisodeRef]]

    var out: [PackFileAssignment]
    var parsed: [Int: ParsedRelease] = [:]
    var classes: [FileClass]
    var warnings: [PackWarning] = []
    var conflicts: [PackConflict] = []
    var sets: [ArchiveSet] = []
    var seriesTitleNorm: String
    var aliasNorms: [String]

    init(files: [PackFile], series: PackSeriesContext, corrections: [Int: [EpisodeRef]]) {
        self.files = files
        self.series = series
        self.corrections = corrections
        self.classes = files.map { Mapper.classify($0.path) }
        self.out = files.map {
            PackFileAssignment(
                fileIndex: $0.index, path: $0.path, size: $0.size, offset: $0.offset, role: .nonMedia,
                confidence: 1, reason: "")
        }
        self.seriesTitleNorm = ReleaseParser.normalizeTitle(series.title)
        self.aliasNorms = series.aliases.map(ReleaseParser.normalizeTitle)
    }

    static func classify(_ path: String) -> FileClass {
        let name = ArchiveGrouper.fileName(path)
        let ext = name.lastIndex(of: ".").map { name[name.index(after: $0)...].lowercased() } ?? ""
        if executableExts.contains(ext) { return .executable }
        if subtitleExts.contains(ext) { return .subtitle }
        if videoExts.contains(ext) { return .video }
        if ArchiveGrouper.isArchiveName(name) { return .archive }
        return .nonMedia
    }

    // MARK: Driver

    mutating func run() -> PackMappingResult {
        // 1. Parse videos, derive the pack-wide season hint.
        for (i, f) in files.enumerated() where classes[i] == .video { parsed[f.index] = ReleaseParser.parseFileName(f.path) }
        let dominant = dominantSeason()

        // 2. Videos.
        for (i, f) in files.enumerated() {
            switch classes[i] {
            case .video: classifyVideo(i, f, dominantSeason: dominant)
            case .executable:
                out[i].role = .nonMedia
                out[i].isSuspicious = true
                out[i].confidence = 1
                out[i].reason = "Executable file; never opened or downloaded by default (possible malware)"
                warnings.append(.suspiciousExecutable(fileIndex: f.index))
            case .nonMedia:
                out[i].role = .nonMedia
                out[i].reason = "Not a video file (\(extLabel(f.path)))"
            case .subtitle, .archive: break
            }
        }

        // 3. Archives.
        classifyArchives(dominantSeason: dominant)

        // 4. Corrections on everything except subtitles (handled with their sidecar logic).
        applyCorrections()

        // 5. Tiny "episodes" next to full-size ones are samples.
        flagSmallSamples()

        // 6. Duplicates.
        resolveConflicts()

        // 7. Subtitles.
        classifySubtitles()

        // 8. Gaps and warnings.
        let (gaps, opaque) = computeGaps()
        for a in out where a.isUnmatched && a.isPreferred && !a.userCorrected && a.archiveSetID == nil {
            warnings.append(.unmatchedFile(fileIndex: a.fileIndex))
        }
        for s in sets where !s.isComplete {
            warnings.append(.incompleteArchive(setID: s.id, missingVolumes: s.missingVolumes))
        }
        return PackMappingResult(
            assignments: out.sorted { $0.fileIndex < $1.fileIndex }, conflicts: conflicts, gaps: gaps,
            archiveSets: sets, warnings: warnings, hasOpaqueArchives: opaque)
    }

    func extLabel(_ path: String) -> String {
        let n = ArchiveGrouper.fileName(path)
        if let d = n.lastIndex(of: "."), d != n.startIndex { return "." + n[n.index(after: d)...].lowercased() }
        return "no extension"
    }

    // MARK: Season hint

    func dominantSeason() -> Int? {
        var counts: [Int: Int] = [:]
        for (_, r) in parsed where !r.flags.contains(.sample) && !r.flags.contains(.extra) {
            if r.seasons.count == 1, r.seasons[0] != 0, !r.episodes.isEmpty { counts[r.seasons[0], default: 0] += 1 }
        }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    // MARK: Resolution

    struct Resolved {
        var refs: [EpisodeRef]
        var confidence: Double
        var reason: String
    }

    /// Finds the episodes a parsed path stands for.
    func resolve(_ r: ParsedRelease, path: String, dominantSeason: Int?) -> Resolved {
        let ctx = series
        let fileName = ArchiveGrouper.fileName(path)
        // Season spelled in the file name itself (vs inherited from a folder).
        let seasonInName: Bool = {
            guard !r.seasons.isEmpty, path.contains("/") || path.contains("\\") else { return true }
            return !ReleaseParser.parse(fileName).seasons.isEmpty
        }()

        if let d = r.airDate {
            if let ref = ctx.byDate[d] { return Resolved(refs: [ref], confidence: 0.95, reason: "Air date \(d) matches \(ref)") }
            if r.episodes.isEmpty {
                return Resolved(refs: [], confidence: 0.3, reason: "Air date \(d) isn't in the episode list")
            }
        }

        // Explicit season + episode(s).
        if let season = r.seasons.first, !r.episodes.isEmpty {
            let refs = r.episodes.map { EpisodeRef(season: season, episode: $0) }
            let listLabel = refsLabel(refs)
            if ctx.episodes.isEmpty || refs.allSatisfy(ctx.contains) {
                let reason = seasonInName
                    ? "\(listLabel) in the file name"
                    : "Episode \(r.episodes.map(String.init).joined(separator: "-")) in the file name; season \(season) from the folder"
                return Resolved(refs: refs, confidence: seasonInName ? 0.98 : 0.92, reason: reason)
            }
            if let viaAbs = absoluteRefs(r.episodes) {
                return Resolved(
                    refs: viaAbs, confidence: 0.7,
                    reason: "\(listLabel) isn't in the episode list; read as absolute number \(r.episodes.map(String.init).joined(separator: "-")) = \(refsLabel(viaAbs))")
            }
            return Resolved(refs: refs, confidence: 0.5, reason: "\(listLabel) isn't in the episode list")
        }

        // Absolute numbers (anime) or bare episode numbers with no season.
        let nums = !r.episodes.isEmpty ? r.episodes : r.absoluteEpisodes
        if !nums.isEmpty {
            if !r.absoluteEpisodes.isEmpty, r.episodes.isEmpty, let viaAbs = absoluteRefs(nums) {
                return Resolved(refs: viaAbs, confidence: 0.88, reason: "Absolute episode \(nums.map(String.init).joined(separator: "-")) = \(refsLabel(viaAbs))")
            }
            if let s = hintSeason(dominantSeason) {
                let refs = nums.map { EpisodeRef(season: s, episode: $0) }
                if ctx.episodes.isEmpty || refs.allSatisfy(ctx.contains) {
                    return Resolved(refs: refs, confidence: 0.75, reason: "No season in the name; assumed season \(s) from the rest of the pack")
                }
                if let viaAbs = absoluteRefs(nums) {
                    return Resolved(refs: viaAbs, confidence: 0.6, reason: "No season in the name; matched absolute number")
                }
                return Resolved(refs: refs, confidence: 0.4, reason: "\(refsLabel(refs)) isn't in the episode list")
            }
            if let viaAbs = absoluteRefs(nums) {
                return Resolved(refs: viaAbs, confidence: 0.6, reason: "No season in the name; matched absolute number")
            }
            return Resolved(refs: [], confidence: 0.3, reason: "Episode number \(nums.map(String.init).joined(separator: "-")) found but the season is unknown")
        }

        // Episode title match.
        if let ref = titleMatch(r) {
            return Resolved(refs: [ref], confidence: 0.7, reason: "File name matches the title of \(ref)")
        }
        return Resolved(refs: [], confidence: 0.5, reason: "No episode number in the name")
    }

    func hintSeason(_ dominant: Int?) -> Int? {
        if series.targetSeasons.count == 1, let s = series.targetSeasons.first, s != 0 { return s }
        if let d = dominant { return d }
        if series.regularSeasons.count == 1 { return series.regularSeasons.first }
        if series.episodes.isEmpty { return 1 }
        return nil
    }

    func absoluteRefs(_ nums: [Int]) -> [EpisodeRef]? {
        guard !nums.isEmpty else { return nil }
        var out: [EpisodeRef] = []
        for n in nums {
            guard let r = series.byAbsolute[n] else { return nil }
            out.append(r)
        }
        return out
    }

    func titleMatch(_ r: ParsedRelease) -> EpisodeRef? {
        guard !series.byTitle.isEmpty else { return nil }
        for cand in [r.episodeTitle, r.title] {
            guard let c = cand else { continue }
            var n = ReleaseParser.normalizeTitle(c)
            if !seriesTitleNorm.isEmpty, n.hasPrefix(seriesTitleNorm + " ") { n = String(n.dropFirst(seriesTitleNorm.count + 1)) }
            if let ref = series.byTitle[n] { return ref }
        }
        return nil
    }

    func refsLabel(_ refs: [EpisodeRef]) -> String {
        guard let f = refs.first else { return "" }
        if refs.count == 1 { return f.description }
        return "\(f)-\(refs.last!)"
    }

    /// Looks for episode information in the folders above a file (scene releases keep the episode in the
    /// folder name: `Show.S01E01.720p-GRP/abc.mkv`).
    func ancestorInfo(_ path: String) -> ParsedRelease? {
        let comps = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard comps.count > 1 else { return nil }
        var k = comps.count - 1
        while k >= 1 {
            let prefix = comps[0..<k].joined(separator: "/")
            let r = ReleaseParser.parseFileName(prefix)
            if r.hasEpisodeInfo && !r.isPack { return r }
            k -= 1
        }
        return nil
    }

    // MARK: Videos

    mutating func classifyVideo(_ i: Int, _ f: PackFile, dominantSeason: Int?) {
        guard var r = parsed[f.index] else { return }
        if r.flags.contains(.sample) {
            set(i, role: .sample, refs: [], conf: 0.95, reason: "Sample (named or filed as a sample)")
            return
        }
        // "S00E01 Behind The Scenes" is a numbered special, not loose bonus content.
        let numberedSpecial = r.seasons == [0] && !r.episodes.isEmpty
        if r.flags.contains(.extra), !numberedSpecial {
            set(i, role: .extra, refs: [], conf: 0.9, reason: "Extra (bonus content folder or name)")
            return
        }
        var viaFolder = false
        if !r.hasEpisodeInfo, let a = ancestorInfo(f.path) {
            // Keep the file's own quality tags but take the episode numbering from the folder.
            r.seasons = a.seasons
            r.episodes = a.episodes
            r.absoluteEpisodes = a.absoluteEpisodes
            r.airDate = a.airDate
            viaFolder = true
        }
        var res = resolve(r, path: f.path, dominantSeason: dominantSeason)
        if viaFolder, !res.refs.isEmpty { res.reason += " (from the folder name)"; res.confidence = min(res.confidence, 0.9) }

        if res.refs.isEmpty {
            if r.isSpecial || r.seasons == [0] {
                set(i, role: .special, refs: [], conf: min(res.confidence, 0.4), reason: "In a specials folder but no episode number found")
            } else if res.confidence >= 0.5, !r.hasEpisodeInfo {
                set(i, role: .extra, refs: [], conf: 0.55, reason: "No episode number in the name; treated as an extra")
            } else {
                set(i, role: .episode, refs: [], conf: res.confidence, reason: res.reason)
            }
            return
        }
        if titleMismatch(r) {
            res.confidence = max(0.1, res.confidence - 0.1)
            res.reason += "; title \"\(r.title)\" differs from the series"
            warnings.append(.titleMismatch(fileIndex: f.index))
        }
        set(i, role: roleFor(res.refs), refs: res.refs, conf: res.confidence, reason: res.reason)
    }

    func roleFor(_ refs: [EpisodeRef]) -> PackRole {
        if refs.count > 1 { return .multiEpisode }
        if refs.first?.season == 0 { return .special }
        return .episode
    }

    mutating func set(_ i: Int, role: PackRole, refs: [EpisodeRef], conf: Double, reason: String) {
        out[i].role = role
        out[i].episodes = refs
        out[i].confidence = conf
        out[i].reason = reason
    }

    func titleMismatch(_ r: ParsedRelease) -> Bool {
        let t = r.normalizedTitle
        if t.isEmpty || seriesTitleNorm.isEmpty { return false }
        for s in [seriesTitleNorm] + aliasNorms where !s.isEmpty {
            if t == s || t.contains(s) || s.contains(t) { return false }
            let a = Set(t.split(separator: " ")), b = Set(s.split(separator: " "))
            if Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count))) >= 0.5 { return false }
        }
        return true
    }

    // MARK: Archives

    mutating func classifyArchives(dominantSeason: Int?) {
        let archiveFiles = files.enumerated().filter { classes[$0.offset] == .archive }.map(\.element)
        guard !archiveFiles.isEmpty else { return }
        var built = ArchiveGrouper.group(archiveFiles)
        var pos: [Int: Int] = [:]
        for (i, f) in files.enumerated() { pos[f.index] = i }
        for si in built.indices {
            let s = built[si]
            let dir = s.directory
            let synthetic = (dir.isEmpty ? "" : dir + "/") + s.baseName + ".rar"
            var r = ReleaseParser.parseFileName(synthetic)
            r.flags.remove(.archive)
            var role = PackRole.archiveVolume
            var refs: [EpisodeRef] = []
            var conf = 0.5
            var reason = ""
            if r.flags.contains(.sample) {
                role = .sample; conf = 0.9; reason = "Sample archive"
            } else if r.flags.contains(.extra) {
                role = .extra; conf = 0.85; reason = "Extra archive"
            } else {
                var viaFolder = false
                if !r.hasEpisodeInfo, let a = ancestorInfo(synthetic) {
                    r.seasons = a.seasons; r.episodes = a.episodes; r.absoluteEpisodes = a.absoluteEpisodes
                    r.airDate = a.airDate
                    viaFolder = true
                }
                let res = resolve(r, path: synthetic, dominantSeason: dominantSeason)
                refs = res.refs
                conf = res.confidence
                reason = "Archive volume set: " + res.reason + (viaFolder && !refs.isEmpty ? " (from the folder name)" : "")
                if refs.isEmpty { reason = "Archive volume set with no episode number in its name; contents unknown" }
            }
            built[si].episodes = refs
            for (vi, v) in s.volumes.enumerated() {
                let i = pos[v.fileIndex]!
                out[i].role = role
                out[i].episodes = refs
                out[i].confidence = conf
                out[i].reason = reason + (s.volumes.count > 1 ? " (volume \(vi + 1) of \(s.volumes.count))" : "")
                if role == .archiveVolume {
                    out[i].archiveSetID = s.id
                    out[i].archiveVolume = vi
                }
            }
        }
        sets = built
    }

    // MARK: Corrections

    mutating func applyCorrections() {
        guard !corrections.isEmpty else { return }
        var pos: [Int: Int] = [:]
        for (i, f) in files.enumerated() { pos[f.index] = i }
        for (idx, refs) in corrections {
            guard let i = pos[idx], classes[i] != .subtitle else { continue }
            var targets = [i]
            if let sid = out[i].archiveSetID, let s = sets.first(where: { $0.id == sid }) {
                targets = s.volumes.compactMap { pos[$0.fileIndex] }
                if let si = sets.firstIndex(where: { $0.id == sid }) { sets[si].episodes = refs.sorted() }
            }
            for t in targets {
                let refs = refs.sorted()
                if refs.isEmpty {
                    out[t].role = .extra
                    out[t].reason = "Marked as not an episode by you"
                } else {
                    if out[t].archiveSetID == nil { out[t].role = roleFor(refs) }
                    out[t].reason = "Set by you"
                }
                out[t].episodes = refs
                out[t].confidence = 1
                out[t].userCorrected = true
                out[t].isPreferred = true
                if refs.isEmpty { out[t].archiveSetID = nil; out[t].archiveVolume = nil }
            }
        }
    }

    // MARK: Samples by size

    mutating func flagSmallSamples() {
        let sizes = out.filter { $0.role == .episode || $0.role == .multiEpisode }.map(\.size).filter { $0 > 0 }.sorted()
        guard sizes.count >= 3 else { return }
        let median = sizes[sizes.count / 2]
        guard median >= 200 << 20 else { return }
        for i in out.indices where (out[i].role == .episode || out[i].role == .multiEpisode) && !out[i].userCorrected {
            if out[i].size < 80 << 20, Double(out[i].size) < Double(median) * 0.08 {
                out[i].role = .sample
                out[i].episodes = []
                out[i].confidence = 0.7
                out[i].reason = "Much smaller than the other episodes; treated as a sample"
            }
        }
    }

    // MARK: Conflicts

    struct Quality: Comparable {
        var corrected: Int
        var loose: Int
        var resolution: Int
        var source: Int
        var version: Int
        var size: Int64
        static func < (l: Quality, r: Quality) -> Bool {
            (l.corrected, l.loose, l.resolution, l.source, l.version, l.size) < (r.corrected, r.loose, r.resolution, r.source, r.version, r.size)
        }
    }

    static func sourceRank(_ s: Source?) -> Int {
        switch s {
        case .remux?: 8
        case .bluRay?: 7
        case .webDL?: 6
        case .webRip?: 5
        case .hdtv?: 4
        case .dvd?: 3
        case .sdtv?: 2
        case nil: 1
        default: 0
        }
    }

    struct Unit {
        var files: [Int]  // positions into `out`
        var refs: [EpisodeRef]
        var quality: Quality
        var lead: Int  // file index used to report
    }

    mutating func resolveConflicts() {
        var units: [Unit] = []
        var seenSets = Set<String>()
        for (i, a) in out.enumerated() {
            guard a.carriesEpisodes, !a.episodes.isEmpty else { continue }
            if let sid = a.archiveSetID {
                guard seenSets.insert(sid).inserted, let s = sets.first(where: { $0.id == sid }) else { continue }
                var pos: [Int: Int] = [:]
                for (j, x) in out.enumerated() { pos[x.fileIndex] = j }
                let ps = s.volumes.compactMap { pos[$0.fileIndex] }
                units.append(Unit(
                    files: ps, refs: a.episodes,
                    quality: Quality(corrected: a.userCorrected ? 1 : 0, loose: 0, resolution: 0, source: 0, version: 1, size: s.totalSize),
                    lead: s.volumes[0].fileIndex))
            } else {
                let r = parsed[a.fileIndex]
                units.append(Unit(
                    files: [i], refs: a.episodes,
                    quality: Quality(
                        corrected: a.userCorrected ? 1 : 0, loose: 1, resolution: r?.resolution?.rawValue ?? 0,
                        source: Mapper.sourceRank(r?.source), version: r?.version ?? 1, size: a.size),
                    lead: a.fileIndex))
            }
        }
        units.sort { l, r in
            if l.quality != r.quality { return l.quality > r.quality }
            return l.lead < r.lead
        }
        var owner: [EpisodeRef: Int] = [:]  // ref -> lead file index of the winner
        var contested: [EpisodeRef: [Int]] = [:]
        var lost: [Unit] = []
        for u in units {
            let unclaimed = u.refs.filter { owner[$0] == nil }
            if unclaimed.isEmpty {
                lost.append(u)
                for r in u.refs { contested[r, default: []].append(u.lead) }
                continue
            }
            for r in u.refs {
                if let w = owner[r], w != u.lead { contested[r, default: []].append(u.lead) }
            }
            for r in unclaimed { owner[r] = u.lead }
        }
        for u in lost {
            let winnerName = u.refs.first.flatMap { owner[$0] }.map { out[$0].path } ?? ""
            for p in u.files {
                out[p].isPreferred = false
                out[p].reason += "; not used: another file already covers \(refsLabel(u.refs))" + (winnerName.isEmpty ? "" : " (\(ArchiveGrouper.fileName(winnerName)))")
            }
        }
        for (ref, losers) in contested.sorted(by: { $0.key < $1.key }) {
            guard let w = owner[ref] else { continue }
            let ls = Array(Set(losers)).sorted()
            let why = out[w].userCorrected ? "your correction" : "higher quality, non-archive, then larger"
            conflicts.append(PackConflict(episode: ref, winner: w, losers: ls, reason: "Kept the file chosen by \(why)"))
        }
        // Mark partially overlapping winners with a note so the review table explains them.
        for c in conflicts where !c.losers.isEmpty {
            if let p = out.firstIndex(where: { $0.fileIndex == c.winner }), !out[p].reason.contains("Duplicate") {
                out[p].reason += "; also claimed by \(c.losers.count) other file\(c.losers.count == 1 ? "" : "s")"
            }
        }
    }

    // MARK: Subtitles

    mutating func classifySubtitles() {
        var pos: [Int: Int] = [:]
        for (i, f) in files.enumerated() { pos[f.index] = i }
        // Stem -> video position for same-name sidecars.
        var stems: [String: Int] = [:]
        for (i, a) in out.enumerated() where classes[i] == .video {
            let stem = stemOf(ArchiveGrouper.fileName(a.path)).lowercased()
            if stems[stem] == nil { stems[stem] = i }
        }
        // Preferred carrier per episode.
        var carrier: [EpisodeRef: Int] = [:]
        for (i, a) in out.enumerated() where a.isPreferred && a.carriesEpisodes {
            for r in a.episodes where carrier[r] == nil { carrier[r] = a.archiveSetID != nil ? firstVolume(of: a, pos: pos) : i }
        }

        for (i, f) in files.enumerated() where classes[i] == .subtitle {
            out[i].role = .subtitle
            if let refs = corrections[f.index] {
                let sorted = refs.sorted()
                out[i].episodes = sorted
                out[i].confidence = 1
                out[i].userCorrected = true
                out[i].reason = sorted.isEmpty ? "Marked as unattached by you" : "Set by you"
                out[i].attachedTo = sorted.first.flatMap { carrier[$0] }.map { out[$0].fileIndex }
                continue
            }
            // 1. Same file name as a video (minus language tags).
            var candidate = stemOf(ArchiveGrouper.fileName(f.path)).lowercased()
            var matched: Int?
            for _ in 0..<4 {
                if let v = stems[candidate] { matched = v; break }
                guard let dot = candidate.lastIndex(of: ".") else { break }
                candidate = String(candidate[..<dot])
            }
            if let v = matched {
                out[i].attachedTo = out[v].fileIndex
                out[i].episodes = out[v].episodes
                out[i].isPreferred = out[v].isPreferred
                out[i].confidence = 0.95
                out[i].reason = "Same name as \(ArchiveGrouper.fileName(out[v].path))"
                if out[v].role == .sample { out[i].role = .sample; out[i].episodes = [] }
                continue
            }
            // 2. Episode number from the path.
            let nameStem = stemOf(ArchiveGrouper.fileName(f.path)).lowercased()
            let langOnly = isLanguageOnly(nameStem)
            var r: ParsedRelease?
            var viaFolder = false
            if langOnly || !(ReleaseParser.parseFileName(f.path).hasEpisodeInfo) {
                if let a = ancestorInfo(f.path) { r = a; viaFolder = true }
            }
            if r == nil {
                let p = ReleaseParser.parseFileName(f.path)
                if p.hasEpisodeInfo && !langOnly { r = p }
            }
            if let r, !r.flags.contains(.sample) {
                let res = resolve(r, path: f.path, dominantSeason: dominantSeason())
                if !res.refs.isEmpty {
                    out[i].episodes = res.refs
                    out[i].confidence = min(res.confidence, 0.85)
                    out[i].reason = "Subtitle for \(refsLabel(res.refs))" + (viaFolder ? " (from the folder name)" : "")
                    if let c = res.refs.compactMap({ carrier[$0] }).first {
                        out[i].attachedTo = out[c].fileIndex
                        out[i].isPreferred = out[c].isPreferred
                    } else {
                        out[i].reason += "; no matching video in the pack"
                    }
                    continue
                }
            }
            if r?.flags.contains(.sample) == true || f.path.lowercased().contains("sample") {
                out[i].role = .sample
                out[i].confidence = 0.8
                out[i].reason = "Subtitle of a sample"
                continue
            }
            out[i].confidence = 0.3
            out[i].reason = "Subtitle file that couldn't be matched to an episode"
        }
    }

    func firstVolume(of a: PackFileAssignment, pos: [Int: Int]) -> Int? {
        guard let sid = a.archiveSetID, let s = sets.first(where: { $0.id == sid }) else { return pos[a.fileIndex] }
        return pos[s.volumes[0].fileIndex]
    }

    func stemOf(_ name: String) -> String {
        if let d = name.lastIndex(of: "."), d != name.startIndex { return String(name[..<d]) }
        return name
    }

    func isLanguageOnly(_ stem: String) -> Bool {
        var s = Substring(stem)
        while let c = s.first, c.isNumber || c == "_" || c == "-" || c == " " || c == "." { s = s.dropFirst() }
        if s.isEmpty { return true }
        let words = s.split(whereSeparator: { "._- ()[]".contains($0) })
        return !words.isEmpty && words.allSatisfy { languageWords.contains(String($0)) }
    }

    // MARK: Gaps

    func computeGaps() -> ([EpisodeRef], Bool) {
        let opaque = sets.contains { set in
            set.episodes.isEmpty && out.contains(where: { $0.archiveSetID == set.id })
        }
        guard !series.episodes.isEmpty else { return ([], opaque) }
        var covered = Set<EpisodeRef>()
        var seasons = Set<Int>()
        for a in out where a.isPreferred && a.carriesEpisodes {
            if let sid = a.archiveSetID, let s = sets.first(where: { $0.id == sid }), !s.isComplete { continue }
            for r in a.episodes { covered.insert(r) }
        }
        for a in out where a.isPreferred && a.carriesEpisodes {
            for r in a.episodes where r.season != 0 { seasons.insert(r.season) }
        }
        seasons.formUnion(series.targetSeasons.filter { $0 != 0 })
        guard !seasons.isEmpty else { return ([], opaque) }
        let gaps = series.episodes
            .filter { $0.isAired && seasons.contains($0.ref.season) && !covered.contains($0.ref) }
            .map(\.ref).sorted()
        return (opaque ? [] : gaps, opaque)
    }
}
