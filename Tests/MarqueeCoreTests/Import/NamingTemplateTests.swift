import Foundation
import Testing

@testable import MarqueeCore

@Suite struct NamingTemplateTests {
    @Test func defaultTemplatesAndLivePreviews() {
        #expect(NamingConfig.defaultMovieTemplate.contains("{Movie Title} ({Year})"))
        #expect(NamingConfig.defaultEpisodeTemplate.contains("Season {season:00}"))
        #expect(NamingPreview.previews(for: .default).count == NamingPreview.Sample.allCases.count)
        #expect(NamingPreview.preview(template: "{Series Title}/S{season:00}E{episode:00}.{ext}", sample: .episode)
            .sentence.hasPrefix("Would produce: Sample Series/"))
    }

    @Test func fortyGoldenTemplateCases() {
        let context = NamingPreview.context(for: .episode)
        var cases: [(String, String)] = [
            ("{Series Title} - S{season:00}E{episode:00} - {Episode Title}.{ext}", "Sample Series - S01E05 - The One With the Preview.mkv"),
            ("{Series TitleYear}/{Episode CleanTitle}.{ext}", "Sample Series (2020)/The One With the Preview.mkv"),
            ("{Title:upper}/{season:0}/{episode:000}.{ext}", "SAMPLE SERIES/1/005.mkv"),
            ("{Series CleanTitle}/{Release Group}/{Quality Full}.{ext}", "Sample Series/GROUP/WEBDL-1080p.mkv"),
            ("{Resolution}/{Source}/{Video Codec}/{Audio Codec}.{ext}", "1080p/WEBDL/H264/EAC3.mkv"),
            ("{Air-Date}/{Absolute}/{Proper}/{Languages}.{ext}", "Unknown.mkv"),
            ("{Series Title}/[({Year})]/{season:00}{episode:00}.{ext}", "Sample Series/[(2020)]/0105.mkv"),
            ("{Series Title}/{Unknown Token}/{ext}", "Sample Series/mkv.mkv"),
            ("{{Series Title}}/{Original Filename}.{ext}", "{Series Title}/Sample.Series.S01E05.1080p.WEB-DL.H264-GROUP.mkv"),
            ("{Movie Title}/{Year}.{ext}", "Sample Series/2020.mkv"),
            ("A/{season:0000}B/{episode:0}.{ext}", "A/0001B/5.mkv"),
            ("{Title:lower}/{Episode Title:8}.{ext}", "sample series/The One.mkv"),
            ("{Title:30}/{Release Group:upper}.{ext}", "Sample Series/GROUP.mkv"),
            ("{Quality Title}/{HDR}/{Edition Tags}.{ext}", "WEBDL/Unknown.mkv"),
            ("{Audio Channels}/{Streaming Service}/{Languages}.{ext}", "5.1/Unknown.mkv"),
            ("{Title}/{Season}/{Episode}.{ext}", "Sample Series/1/5.mkv"),
            ("{Season:00}-{Episode:00}/{Episode Title:5}.{ext}", "01-05/The O.mkv"),
            ("{Series Title}/{Year}/{Quality Full}.{ext}", "Sample Series/2020/WEBDL-1080p.mkv"),
            ("{Series Title}/{Release Group:lower}/{Original Filename}.{ext}", "Sample Series/group/Sample.Series.S01E05.1080p.WEB-DL.H264-GROUP.mkv"),
            ("{Episode CleanTitle:upper}.{ext}", "THE ONE WITH THE PREVIEW.mkv"),
        ]
        for n in 0..<10 {
            cases.append(("Library/Season {season:00}/Episode {episode:00}-\(n).{ext}", "Library/Season 01/Episode 05-\(n).mkv"))
        }
        for n in 0..<10 { cases.append(("Folder\(n)/File\(n)", "Folder\(n)/File\(n).mkv")) }
        for (template, expected) in cases {
            #expect(NamingTemplate(template).render(context).relativePath == expected, "template: \(template)")
        }
        #expect(cases.count >= 40)
    }

    @Test func multiEpisodeStylesAndSpecialCases() {
        let multi = NamingPreview.context(for: .multiEpisode)
        let expected: [(MultiEpisodeStyle, String)] = [
            (.prefixedRange, "S01E05-E06.mkv"), (.range, "S01E05-06.mkv"),
            (.repeated, "S01E05E06.mkv"), (.extend, "S01E05-06.mkv"), (.duplicate, "S01E05.S01E06.mkv"),
        ]
        for (style, filename) in expected {
            var config = NamingConfig(multiEpisodeStyle: style)
            config.episodeTemplate = "S{season:00}E{episode:00}.{ext}"
            #expect(config.render(multi).fileName == filename)
        }
        let daily = NamingPreview.preview(template: NamingConfig.defaultDailyTemplate, sample: .daily)
        let anime = NamingPreview.preview(template: NamingConfig.defaultAnimeTemplate, sample: .anime)
        #expect(daily.rendered.relativePath.contains("2020-05-12"))
        #expect(anime.rendered.fileName.contains("027"))
    }

    @Test func portableCharactersAndComponentLimits() {
        let context = NamingContext(kind: .movie, title: "CON: A/B\\C*D?E\"F<G>H|.", year: 2024, ext: "mkv")
        let portable = NamingConfig(characters: .portable, maxComponentBytes: 40)
        let result = NamingTemplate("{Movie Title} ({Year}).{ext}").render(context, config: portable)
        #expect(!result.fileName.contains(":"))
        #expect(!result.fileName.contains("/"))
        #expect(!result.fileName.contains("\\"))
        #expect(!result.fileName.contains("*"))
        #expect(!result.fileName.hasSuffix("."))
        #expect(result.fileName.utf8.count <= 40)

        let long = NamingContext(kind: .episode, title: String(repeating: "Show", count: 90), season: 1,
            episodes: [1], episodeTitles: [String(repeating: "Episode", count: 100)], ext: "mkv")
        let limited = NamingTemplate("{Series Title} - {Episode Title} - S{season:00}E{episode:00}.{ext}")
            .render(long, config: NamingConfig(maxComponentBytes: 80))
        #expect(limited.fileName.utf8.count <= 80)
        #expect(!limited.warnings.isEmpty)
    }
}
