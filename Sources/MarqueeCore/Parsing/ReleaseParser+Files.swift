extension ReleaseParser {
    /// Parse a path inside a torrent (`Show.S01.1080p/Episode 03.mkv`). The file name is parsed first;
    /// parent folders then supply whatever it lacks: show title, year, season, quality, group.
    /// Folders such as `Season 2`, `Specials`, `Extras` and `Sample` contribute season/flag context only.
    public static func parseFileName(_ path: String) -> ParsedRelease {
        let comps = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let file = comps.last else { return parseCore(path, lenient: false) }
        let folders = Array(comps.dropLast())
        if folders.isEmpty {
            var r = parseCore(file, lenient: false)
            r.input = path
            return r
        }

        var ctx = FolderContext()
        for f in folders { ctx.absorb(f) }

        var r = parseCore(file, lenient: false)
        let skipLenient = r.flags.contains(.sample) || r.flags.contains(.extra) || ctx.sample || ctx.extra
        if !r.hasEpisodeInfo, ctx.isTV, !skipLenient {
            let lp = parseCore(file, lenient: true)
            if lp.hasEpisodeInfo { r = lp }
        }
        r.input = path
        ctx.merge(into: &r)
        return r
    }
}

private struct FolderContext {
    var base: ParsedRelease?
    var seasons: [Int] = []
    var extra = false
    var sample = false

    var isTV: Bool {
        if !seasons.isEmpty { return true }
        guard let b = base else { return false }
        switch b.kind {
        case .seasonPack, .multiSeason, .completeSeries, .episode, .daily, .animeAbsolute: return true
        default: return false
        }
    }

    mutating func absorb(_ folder: String) {
        let key = folder.lowercased().split(whereSeparator: { " ._-".contains($0) }).joined(separator: " ")
        if Vocabulary.extrasFolders.contains(key) { extra = true; return }
        if key == "sample" || key == "samples" || key == "proof" || key == "proofs" { sample = true; return }
        if key == "specials" || key == "special" { seasons = [0]; return }
        if key == "subs" || key == "subtitles" || key == "sub" || key == "subtitle" { return }
        let p = ReleaseParser.parseCore(folder, lenient: false)
        let hasAnchor = p.year != nil || !p.seasons.isEmpty || !p.episodes.isEmpty || p.resolution != nil
            || p.source != nil || p.videoCodec != nil || p.airDate != nil || !p.absoluteEpisodes.isEmpty
            || p.releaseGroup != nil || p.kind == .completeSeries
        if p.title.isEmpty {
            if !p.seasons.isEmpty { seasons = p.seasons }
            return
        }
        if hasAnchor || base == nil {
            if !p.seasons.isEmpty { seasons = p.seasons }
            if var b = base, hasAnchor {
                b.overlay(p)
                base = b
            } else if base == nil {
                base = p
            }
        }
    }

    func merge(into r: inout ParsedRelease) {
        if extra { r.flags.insert(.extra) }
        if sample { r.flags.insert(.sample) }
        if let b = base {
            let fileAnchorless = r.year == nil && r.resolution == nil && r.source == nil && r.videoCodec == nil
                && !r.hasEpisodeInfo && r.seasons.isEmpty
            let ft = r.normalizedTitle.filter { $0 != " " }, bt = b.normalizedTitle.filter { $0 != " " }
            if r.title.isEmpty || (fileAnchorless && !bt.isEmpty) || (!bt.isEmpty && ft.contains(bt) && ft != bt) {
                if !r.title.isEmpty && r.episodeTitle == nil && fileAnchorless { r.episodeTitle = r.title }
                r.title = b.title
            }
            if r.year == nil { r.year = b.year }
            if r.resolution == nil { r.resolution = b.resolution }
            if r.source == nil { r.source = b.source }
            if r.videoCodec == nil { r.videoCodec = b.videoCodec }
            if r.hdr.isEmpty { r.hdr = b.hdr }
            if r.bitDepth == nil { r.bitDepth = b.bitDepth }
            if r.audioCodecs.isEmpty { r.audioCodecs = b.audioCodecs }
            if r.audioChannels == nil { r.audioChannels = b.audioChannels }
            if r.languages.isEmpty { r.languages = b.languages }
            if r.releaseGroup == nil { r.releaseGroup = b.releaseGroup }
            if r.streamingService == nil { r.streamingService = b.streamingService }
            if r.editions.isEmpty { r.editions = b.editions }
            if b.flags.contains(.proper) { r.flags.insert(.proper) }
            if b.flags.contains(.repack) { r.flags.insert(.repack) }
            if b.flags.contains(.hardcodedSubs) { r.flags.insert(.hardcodedSubs) }
            if b.version > r.version { r.version = b.version }
        }
        if r.seasons.isEmpty && !seasons.isEmpty && seasons.count == 1 {
            if !r.episodes.isEmpty {
                r.seasons = seasons
            } else if !r.absoluteEpisodes.isEmpty, let mx = r.absoluteEpisodes.max(), mx <= 99, r.airDate == nil {
                r.seasons = seasons
                r.episodes = r.absoluteEpisodes
            }
        }
        if r.seasons == [0] { r.isSpecial = true }
        if !r.episodes.isEmpty, r.kind != .daily { r.kind = .episode }
        if r.kind == .unknown {
            if let b = base, b.kind == .movie, !isTV { r.kind = .movie }
            else if !isTV, r.year != nil || r.resolution != nil || r.source != nil || r.videoCodec != nil { r.kind = .movie }
        }
    }
}

extension ParsedRelease {
    var hasEpisodeInfo: Bool { !episodes.isEmpty || !absoluteEpisodes.isEmpty || airDate != nil }

    mutating func overlay(_ o: ParsedRelease) {
        if !o.title.isEmpty { title = o.title }
        if o.year != nil { year = o.year }
        if !o.seasons.isEmpty { seasons = o.seasons }
        if o.kind != .movie && o.kind != .unknown { kind = o.kind } else if kind == .unknown { kind = o.kind }
        if o.resolution != nil { resolution = o.resolution }
        if o.source != nil { source = o.source }
        if o.videoCodec != nil { videoCodec = o.videoCodec }
        if !o.hdr.isEmpty { hdr = o.hdr }
        if o.bitDepth != nil { bitDepth = o.bitDepth }
        if !o.audioCodecs.isEmpty { audioCodecs = o.audioCodecs }
        if o.audioChannels != nil { audioChannels = o.audioChannels }
        if !o.languages.isEmpty { languages = o.languages }
        if o.releaseGroup != nil { releaseGroup = o.releaseGroup }
        if o.streamingService != nil { streamingService = o.streamingService }
        if !o.editions.isEmpty { editions = o.editions }
        flags.formUnion(o.flags.intersection([.proper, .repack, .hardcodedSubs]))
        if o.version > version { version = o.version }
    }
}
