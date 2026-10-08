import Testing
@testable import MarqueeCore

/// Targeted cases for tricky names; the broad corpus lives in `ParsingFixtureCorpusTests`.
@Suite("Release parser")
struct ReleaseParserTests {
    @Test func titlesContainingNumbersAndYears() {
        let a = ReleaseParser.parse("2001.A.Space.Odyssey.1968.1080p.BluRay.x264-GRP")
        #expect(a.title == "2001 A Space Odyssey")
        #expect(a.year == 1968)
        #expect(a.kind == .movie)

        let b = ReleaseParser.parse("1923.S01E01.1080p.WEB.h264-ETHEL")
        #expect(b.title == "1923")
        #expect(b.year == nil)
        #expect(b.seasons == [1] && b.episodes == [1])

        let c = ReleaseParser.parse("9-1-1.S02E03.720p.HDTV.x264-GRP")
        #expect(c.title == "9-1-1")
        #expect(c.seasons == [2] && c.episodes == [3])

        let d = ReleaseParser.parse("1917.2019.1080p.BluRay.x264-SPARKS")
        #expect(d.title == "1917")
        #expect(d.year == 2019)

        let e = ReleaseParser.parse("Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-GRP")
        #expect(e.title == "Blade Runner 2049")
        #expect(e.year == 2017)

        let f = ReleaseParser.parse("Fahrenheit.451.1080p.BluRay.x264-GRP")
        #expect(f.title == "Fahrenheit 451")
        #expect(f.episodes.isEmpty)
    }

    @Test func seasonPackForms() {
        let a = ReleaseParser.parse("Show.Name.S01.COMPLETE.1080p.BluRay.x264-GRP")
        #expect(a.kind == .seasonPack && a.seasons == [1] && a.isPack)

        let b = ReleaseParser.parse("Show.Name.S01-S03.720p.HDTV.x264-GRP")
        #expect(b.kind == .multiSeason && b.seasons == [1, 2, 3])

        let c = ReleaseParser.parse("Show Name Season 1-3 1080p")
        #expect(c.kind == .multiSeason && c.seasons == [1, 2, 3])

        let d = ReleaseParser.parse("Show.Name.Complete.Series.1080p.BluRay.x264-GRP")
        #expect(d.kind == .completeSeries && d.seasons.isEmpty)

        let e = ReleaseParser.parse("Show.Name.S00.Specials.720p")
        #expect(e.seasons == [0] && e.isSpecial)
    }

    @Test func multiEpisodeForms() {
        #expect(ReleaseParser.parse("Show.S01E01E02.720p.HDTV").episodes == [1, 2])
        #expect(ReleaseParser.parse("Show.S01E01-E03.720p.HDTV").episodes == [1, 2, 3])
        #expect(ReleaseParser.parse("Show.S01E01-03.720p.HDTV").episodes == [1, 2, 3])
        #expect(ReleaseParser.parse("Show.1x01-1x03.HDTV").episodes == [1, 2, 3])
        let bare = ReleaseParser.parse("Show.Name.101.720p.HDTV.x264-GRP")
        #expect(bare.seasons == [1] && bare.episodes == [1])
        // Resolutions and years must never be read as SSEE.
        #expect(ReleaseParser.parse("Movie.Name.2019.720p.BluRay.x264-GRP").episodes.isEmpty)
        #expect(ReleaseParser.parse("Movie.Name.720.BluRay").episodes.isEmpty)
    }

    @Test func animeAbsoluteWithHash() {
        let r = ReleaseParser.parse("[SubsPlease] Title - 1071 (1080p) [ABCD1234].mkv")
        #expect(r.title == "Title")
        #expect(r.releaseGroup == "SubsPlease")
        #expect(r.absoluteEpisodes == [1071])
        #expect(r.resolution == .p1080)
        #expect(r.crc32 == "ABCD1234")
        #expect(r.container == "mkv")
        #expect(r.kind == .animeAbsolute)
    }

    @Test func dailyShows() {
        let r = ReleaseParser.parse("The.Daily.Show.2019.05.12.720p.WEB.h264-TBS")
        #expect(r.kind == .daily)
        #expect(r.airDate == AirDate(year: 2019, month: 5, day: 12))
        #expect(r.airDate?.description == "2019-05-12")
        #expect(r.year == nil)
    }

    @Test func qualityAttributes() {
        let r = ReleaseParser.parse("Movie.2021.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-GRP")
        #expect(r.resolution == .p2160)
        #expect(r.source == .remux)
        #expect(r.videoCodec == .h265)
        #expect(r.hdr == [.dolbyVision, .hdr10])
        #expect(r.audioCodecs == [.trueHD, .atmos])
        #expect(r.audioChannels == "7.1")
        #expect(r.releaseGroup == "GRP")

        let w = ReleaseParser.parse("Show.S01E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb")
        #expect(w.source == .webDL && w.streamingService == "AMZN")
        #expect(w.audioCodecs == [.eac3] && w.audioChannels == "5.1")
        #expect(w.videoCodec == .h264)
    }

    @Test func properRepackAndVersion() {
        #expect(ReleaseParser.parse("Show.S01E01.PROPER.720p.HDTV.x264-GRP").version == 2)
        #expect(ReleaseParser.parse("Show.S01E01.REPACK.720p.HDTV.x264-GRP").flags.contains(.repack))
        let v = ReleaseParser.parse("[Group] Show - 05v3 [1080p].mkv")
        #expect(v.version == 3 && v.absoluteEpisodes == [5])
    }

    @Test func titleSurvivesSoftWordsInEpisodeTitles() {
        let r = ReleaseParser.parse("Show.Name.S01E05.The.French.Connection.720p.HDTV.x264-GRP")
        #expect(r.languages.isEmpty)
        #expect(r.episodeTitle == "The French Connection")
        let m = ReleaseParser.parse("The.French.Connection.1971.1080p.BluRay.x264-GRP")
        #expect(m.title == "The French Connection")
        #expect(m.languages.isEmpty)
    }

    @Test func fileInsideSeasonPack() {
        let a = ReleaseParser.parseFileName("Show.Name.S01.1080p.BluRay.x264-GRP/Episode 03.mkv")
        #expect(a.title == "Show Name")
        #expect(a.seasons == [1] && a.episodes == [3])
        #expect(a.resolution == .p1080 && a.releaseGroup == "GRP")
        #expect(a.kind == .episode)

        let b = ReleaseParser.parseFileName("Show Name S01/03 - Title.mkv")
        #expect(b.seasons == [1] && b.episodes == [3] && b.episodeTitle == "Title")

        let c = ReleaseParser.parseFileName("Show.Name.S01-S03.1080p/Season 2/E04.mkv")
        #expect(c.seasons == [2] && c.episodes == [4])

        let d = ReleaseParser.parseFileName("Show.Name.S01.1080p/Extras/Behind the Scenes.mkv")
        #expect(d.flags.contains(.extra))

        let e = ReleaseParser.parseFileName("Show.Name.S01.1080p/Sample/sample.mkv")
        #expect(e.flags.contains(.sample))

        let f = ReleaseParser.parseFileName("Show Name/Specials/01 - Making Of.mkv")
        #expect(f.seasons == [0] && f.episodes == [1] && f.isSpecial)
    }

    @Test func parseRoutesPathsToFileLogic() {
        let r = ReleaseParser.parse("Show.Name.S01.1080p/Episode 03.mkv")
        #expect(r.episodes == [3])
    }

    @Test func degenerateInputsDoNotCrash() {
        for s in ["", " ", ".", "-", "[]", "()", "[", "]]", ".mkv", "...", "S01E01", "1", "2019", "[Group]", "- - -", "é.è.à", "[x]-[y]"] {
            _ = ReleaseParser.parse(s)
            _ = ReleaseParser.parseFileName(s)
        }
        #expect(ReleaseParser.parse("").title.isEmpty)
    }

    @Test func normalizedTitleMatchesAcrossPunctuation() {
        #expect(ReleaseParser.normalizeTitle("Marvel's Agents of S.H.I.E.L.D.") == "marvels agents of shield")
        #expect(ReleaseParser.normalizeTitle("Law & Order") == "law and order")
        #expect(ReleaseParser.normalizeTitle("Spider-Man") == "spider man")
    }

    @Test func determinism() {
        let name = "[SubsPlease] Title - 1071 (1080p) [ABCD1234].mkv"
        #expect(ReleaseParser.parse(name) == ReleaseParser.parse(name))
    }
}
