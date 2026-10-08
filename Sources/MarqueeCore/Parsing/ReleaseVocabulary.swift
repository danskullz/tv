/// Meaning of a single lower-cased token.
enum Word: Sendable {
    case res(Resolution, weak: Bool)
    case src(Source, strong: Bool)
    case codec(VideoCodec)
    case hdr(HDRFormat)
    case bits(Int)
    case audio(AudioCodec)
    case lang(Language, needsContext: Bool)
    case edition(Edition)
    case service(String, ambiguous: Bool)
    case flag(ReleaseFlag)
    case proper, repack, rerip, real
    case special
    case dl
    case noise
}

enum FileKind: Sendable {
    case video, subtitle, archive, nonMedia
}

enum Vocabulary {
    static let words: [String: Word] = {
        var d = [String: Word](minimumCapacity: 700)
        func add(_ keys: String, _ w: Word) {
            for k in keys.split(separator: " ") { d[String(k)] = w }
        }
        // Resolution
        add("480p 480i", .res(.p480, weak: false))
        add("576p 576i", .res(.p576, weak: false))
        add("720p 720i", .res(.p720, weak: false))
        add("1080p 1080i", .res(.p1080, weak: false))
        add("2160p", .res(.p2160, weak: false))
        add("4k uhd", .res(.p2160, weak: true))
        // Sources
        add("bluray bdrip brrip bd25 bd50 bdmv blurayrip bluraycomplete", .src(.bluRay, strong: true))
        add("remux bdremux uhdremux", .src(.remux, strong: true))
        add("webdl webdlrip", .src(.webDL, strong: true))
        add("webrip webhdrip", .src(.webRip, strong: true))
        add("hdtv hdtvrip tvhd", .src(.hdtv, strong: true))
        add("pdtv sdtv dsr dsrip tvrip satrip dvbrip", .src(.sdtv, strong: true))
        add("dvdrip dvdr dvd5 dvd9 dvdrmux", .src(.dvd, strong: true))
        add("dvdscr dvdscreener screener", .src(.screener, strong: true))
        add("camrip hdcam", .src(.cam, strong: true))
        add("telesync hdts", .src(.telesync, strong: true))
        add("telecine hdtc", .src(.telecine, strong: true))
        add("workprint", .src(.workprint, strong: true))
        add("vhsrip", .src(.vhs, strong: true))
        add("web", .src(.webDL, strong: false))
        add("dvd", .src(.dvd, strong: false))
        add("bd", .src(.bluRay, strong: false))
        add("hdrip", .src(.webRip, strong: false))
        add("cam", .src(.cam, strong: false))
        add("ts", .src(.telesync, strong: false))
        add("tc", .src(.telecine, strong: false))
        add("wp", .src(.workprint, strong: false))
        add("scr", .src(.screener, strong: false))
        add("r5 r6", .src(.screener, strong: false))
        add("vhs", .src(.vhs, strong: false))
        // Video codecs
        add("x264 h264 avc avchd", .codec(.h264))
        add("x265 h265 hevc", .codec(.h265))
        add("av1", .codec(.av1))
        add("vp9", .codec(.vp9))
        add("xvid", .codec(.xvid))
        add("divx", .codec(.divx))
        add("mpeg2", .codec(.mpeg2))
        add("vc1", .codec(.vc1))
        // HDR
        add("hdr", .hdr(.hdr))
        add("hdr10", .hdr(.hdr10))
        add("hdr10+ hdr10plus hdr10p", .hdr(.hdr10Plus))
        add("dv dovi dolbyvision", .hdr(.dolbyVision))
        add("hlg", .hdr(.hlg))
        add("sdr", .hdr(.sdr))
        // Bit depth
        add("8bit", .bits(8))
        add("10bit hi10p hi10 10bits", .bits(10))
        add("12bit", .bits(12))
        // Audio
        add("aac aaclc", .audio(.aac))
        add("ac3 dd dolbydigital", .audio(.ac3))
        add("eac3 dd+ ddp ddplus", .audio(.eac3))
        add("dts dca dtses dtshdes", .audio(.dts))
        add("dtshd dtshra", .audio(.dtsHD))
        add("dtshdma dtsma", .audio(.dtsHDMA))
        add("dtsx", .audio(.dtsX))
        add("truehd", .audio(.trueHD))
        add("atmos", .audio(.atmos))
        add("flac", .audio(.flac))
        add("opus", .audio(.opus))
        add("mp3", .audio(.mp3))
        add("lpcm pcm", .audio(.pcm))
        // Languages (full words)
        let langs: [(String, Language)] = [
            ("english", .english), ("french", .french), ("truefrench", .french), ("vff", .french),
            ("vfq", .french), ("vfi", .french), ("vf2", .french), ("vff", .french), ("german", .german),
            ("spanish", .spanish), ("castellano", .spanish), ("latino", .spanish), ("italian", .italian),
            ("italiano", .italian), ("portuguese", .portuguese), ("brazilian", .portuguese),
            ("russian", .russian), ("japanese", .japanese), ("korean", .korean), ("chinese", .chinese),
            ("mandarin", .chinese), ("cantonese", .chinese), ("dutch", .dutch), ("flemish", .dutch),
            ("swedish", .swedish), ("danish", .danish), ("norwegian", .norwegian), ("finnish", .finnish),
            ("polish", .polish), ("czech", .czech), ("hungarian", .hungarian), ("turkish", .turkish),
            ("arabic", .arabic), ("hindi", .hindi), ("thai", .thai), ("greek", .greek),
            ("hebrew", .hebrew), ("ukrainian", .ukrainian), ("vietnamese", .vietnamese),
        ]
        for (k, v) in langs { d[k] = .lang(v, needsContext: false) }
        let codes: [(String, Language)] = [
            ("eng", .english), ("fre", .french), ("fra", .french), ("ger", .german), ("deu", .german),
            ("spa", .spanish), ("ita", .italian), ("por", .portuguese), ("rus", .russian),
            ("jpn", .japanese), ("jap", .japanese), ("kor", .korean), ("chi", .chinese),
            ("zho", .chinese), ("dut", .dutch), ("nld", .dutch), ("swe", .swedish), ("dan", .danish),
            ("nor", .norwegian), ("fin", .finnish), ("pol", .polish), ("cze", .czech),
            ("ces", .czech), ("hun", .hungarian), ("tur", .turkish), ("ara", .arabic),
            ("hin", .hindi), ("tha", .thai), ("gre", .greek), ("heb", .hebrew), ("ukr", .ukrainian),
            ("vie", .vietnamese),
        ]
        for (k, v) in codes { d[k] = .lang(v, needsContext: true) }
        add("multi", .lang(.multi, needsContext: false))
        add("dl", .dl)
        // Editions (single token; multi-token forms are handled in the scanner)
        add("extended", .edition(.extended))
        add("uncut", .edition(.uncut))
        add("unrated", .edition(.unrated))
        add("theatrical", .edition(.theatrical))
        add("imax", .edition(.imax))
        add("remastered remaster", .edition(.remastered))
        add("restored", .edition(.restored))
        add("criterion", .edition(.criterion))
        add("redux", .edition(.redux))
        add("despecialized", .edition(.despecialized))
        add("collectors collector's", .edition(.collectorsEdition))
        add("anniversary", .edition(.anniversaryEdition))
        // Flags
        add("3d hsbs hou sbs", .flag(.threeD))
        add("hc hardsub hardsubs hardcoded hcsub hcsubs korsub", .flag(.hardcodedSubs))
        add("subbed sub subs subtitled engsub engsubs fansub fansubs softsubs vostfr subfrench multisub multisubs", .flag(.subbed))
        add("dubbed dub", .flag(.dubbed))
        add("internal", .flag(.internalRelease))
        add("batch", .flag(.batch))
        add("proper", .proper)
        add("repack", .repack)
        add("rerip", .rerip)
        add("real", .real)
        add("special specials ova oad ona", .special)
        // Noise that should not become a release group or episode title
        add("ws fs retail limited ltd readnfo nfofix dirfix samplefix syncfix subfix hybrid hdlight uhdbd rip ntsc pal", .noise)
        add("lc he hd sd full", .noise)
        // Streaming services
        for k in "amzn amazon nf netflix dsnp dsny atvp atv+ hmax hulu pcok pmtp crav stan itv all4 tubi pluz roku vmeo snet syfy amc amcp bcore cbsn hbo sho showtime stz starz mtv dscp dcu crit mubi hidi funi abema bili vudu ifc tvnz tver dnsp".split(separator: " ") {
            d[String(k)] = .service(canonicalService(String(k)), ambiguous: false)
        }
        for k in "max cc red it ip bbc cbs fox abc nbc cw nick nowtv now comedycentral paramount cr".split(separator: " ") {
            d[String(k)] = .service(canonicalService(String(k)), ambiguous: true)
        }
        return d
    }()

    static func canonicalService(_ k: String) -> String {
        switch k {
        case "amazon": "AMZN"
        case "netflix": "NF"
        case "dsny", "dnsp": "DSNP"
        case "atv+": "ATVP"
        case "showtime": "SHO"
        case "starz": "STZ"
        case "comedycentral": "CC"
        case "paramount": "PMTP"
        case "it": "iT"
        case "ip": "iP"
        case "nowtv": "NOW"
        default: k.uppercased()
        }
    }

    /// Words that may precede digits in a combined audio token (`ddp5`, `aac2`).
    static let audioPrefixes: [String: AudioCodec] = [
        "aac": .aac, "dd": .ac3, "dd+": .eac3, "ddp": .eac3, "dts": .dts, "flac": .flac,
        "opus": .opus, "truehd": .trueHD, "atmos": .atmos, "lpcm": .pcm, "pcm": .pcm,
        "eac3": .eac3, "ac3": .ac3, "dtshd": .dtsHD, "dtshdma": .dtsHDMA, "mp3": .mp3,
    ]

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    static let seasonWords: Set<String> = [
        "season", "seasons", "saison", "staffel", "temporada", "stagione", "seizoen", "sezon", "series",
    ]
    static let episodeWords: Set<String> = ["episode", "episodes", "ep", "eps", "episodio", "folge"]

    static let completeFollowers: Set<String> = [
        "series", "season", "seasons", "collection", "show", "pack", "boxset", "box", "set", "run", "saga",
    ]

    /// Extensions stripped from the end of a name.
    static let extensions: [String: FileKind] = {
        var d: [String: FileKind] = [:]
        for e in "mkv mp4 m4v avi mov wmv mpg mpeg flv webm m2ts ts vob iso ogm divx 3gp mts".split(separator: " ") {
            d[String(e)] = .video
        }
        for e in "srt ass ssa sub idx vtt sup smi sbv".split(separator: " ") { d[String(e)] = .subtitle }
        for e in "rar zip 7z tar gz tgz".split(separator: " ") { d[String(e)] = .archive }
        for e in "nfo txt jpg jpeg png gif exe url sfv md5 db ini diz torrent par2 srr xml log bat sh html htm lnk nzb m3u pdf epub cue mka flac mp3 m4a" .split(separator: " ") {
            d[String(e)] = .nonMedia
        }
        return d
    }()

    /// Bracketed trailing tags that are site marks rather than release groups.
    static let siteTags: Set<String> = [
        "rarbg", "eztv", "ettv", "tgx", "rartv", "eztvx.to", "eztv.re", "eztv.io", "galaxytv", "vxt", "rarbg.com",
        "torrentcouch.com", "torrentgalaxy", "publichd", "1337x", "eztv.ag", "eztv.it", "ethd", "ettv.to",
        "tgx.rs", "torrenting.com", "rarbg.to", "eztv.tf", "cttv", "etrg",
    ]

    /// Suffixes appended by re-posters; they are dropped before parsing.
    static let repostSuffixes: [String] = [
        "-xpost", "-postbot", "-obfuscated", "-scrambled", "-whiterev", "-buymore", "-asrequested",
        "-chamele0n", "-4planet", "-rakuv", "-rakuvfinhel", "-rp", "-wrp", "-sample",
    ]

    static let extrasWords: Set<String> = [
        "featurette", "featurettes", "trailer", "trailers", "bonus", "interview", "interviews",
        "ncop", "nced", "creditless", "blooper", "bloopers", "outtakes", "teaser", "promo", "extras",
    ]

    static let extrasFolders: Set<String> = [
        "extras", "extra", "featurettes", "featurette", "behind the scenes", "deleted scenes",
        "interviews", "trailers", "bonus", "bonus features", "bonus content", "scenes", "shorts",
        "special features", "specials features", "making of",
    ]
}
