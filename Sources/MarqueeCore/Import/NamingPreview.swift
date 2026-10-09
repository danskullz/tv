import Foundation

/// Live preview for the naming settings: what a template would produce for a sample file.
public struct NamingPreview: Sendable, Hashable, Identifiable {
    public enum Sample: String, Sendable, CaseIterable, Hashable {
        case movie, episode, multiEpisode, daily, anime

        public var label: String {
            switch self {
            case .movie: "Movie"
            case .episode: "Episode"
            case .multiEpisode: "Multi-episode file"
            case .daily: "Daily show"
            case .anime: "Anime"
            }
        }
    }

    public var sample: Sample
    public var template: String
    public var rendered: RenderedName
    public var issues: [NamingIssue]

    public var id: Sample { sample }

    /// "Would produce: Show (2020)/Season 01/Show - S01E01 - Pilot [WEBDL-1080p].mkv"
    public var sentence: String { "Would produce: \(rendered.relativePath)" }

    /// Previews `template` as the template for `sample`, using `config` for character handling.
    public static func preview(template: String, sample: Sample, config: NamingConfig = .default) -> NamingPreview {
        let parsed = NamingTemplate(template)
        let context = context(for: sample)
        var tuned = config
        // Render exactly the template being edited, whichever slot it lives in.
        switch sample {
        case .movie: tuned.movieTemplate = template
        case .episode, .multiEpisode: tuned.episodeTemplate = template
        case .daily: tuned.dailyTemplate = template
        case .anime: tuned.animeTemplate = template
        }
        return NamingPreview(
            sample: sample, template: template, rendered: parsed.render(context, config: tuned),
            issues: parsed.validate(forEpisodes: sample != .movie))
    }

    /// One preview per kind of media using the config's own templates.
    public static func previews(for config: NamingConfig) -> [NamingPreview] {
        Sample.allCases.map { sample in
            let template: String
            switch sample {
            case .movie: template = config.movieTemplate
            case .episode, .multiEpisode: template = config.episodeTemplate
            case .daily: template = config.dailyTemplate
            case .anime: template = config.animeTemplate
            }
            return preview(template: template, sample: sample, config: config)
        }
    }

    /// A made-up file of each kind (no real titles).
    public static func context(for sample: Sample) -> NamingContext {
        var parsed = ReleaseParser.parse("Sample.Title.2020.1080p.WEB-DL.DDP5.1.H.264-GROUP")
        parsed.releaseGroup = "GROUP"
        switch sample {
        case .movie:
            return NamingContext(
                kind: .movie, title: "Sample Movie: The Beginning", year: 2020, parsed: parsed,
                originalFilename: "Sample.Movie.2020.1080p.WEB-DL.H264-GROUP.mkv", ext: "mkv")
        case .episode:
            return NamingContext(
                kind: .episode, title: "Sample Series", year: 2020, season: 1, episodes: [5],
                episodeTitles: ["The One With the Preview"], parsed: parsed,
                originalFilename: "Sample.Series.S01E05.1080p.WEB-DL.H264-GROUP.mkv", ext: "mkv")
        case .multiEpisode:
            return NamingContext(
                kind: .episode, title: "Sample Series", year: 2020, season: 1, episodes: [5, 6],
                episodeTitles: ["Part One", "Part Two"], parsed: parsed,
                originalFilename: "Sample.Series.S01E05E06.1080p.WEB-DL.H264-GROUP.mkv", ext: "mkv")
        case .daily:
            return NamingContext(
                kind: .episode, title: "Sample Tonight", year: 2020, seriesType: .daily, season: 2020,
                episodes: [41], airDate: AirDate(year: 2020, month: 5, day: 12), episodeTitles: ["Guest Host"],
                parsed: parsed, originalFilename: "Sample.Tonight.2020.05.12.1080p.WEB-DL.H264-GROUP.mkv", ext: "mkv")
        case .anime:
            return NamingContext(
                kind: .episode, title: "Sample Quest", year: 2020, seriesType: .anime, season: 1, episodes: [3],
                absoluteEpisodes: [27], episodeTitles: ["Departure"], parsed: parsed,
                originalFilename: "[GROUP] Sample Quest - 27 [1080p].mkv", ext: "mkv")
        }
    }
}
