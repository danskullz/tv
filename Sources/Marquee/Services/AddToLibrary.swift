import Foundation
import MarqueeCore

/// A TMDB search hit offered by the add-title sheet.
struct CatalogueResult: Identifiable, Sendable, Hashable {
    var kind: TitleKind
    var tmdbID: Int
    var title: String
    var year: Int?
    var overview: String
    var posterURL: URL?
    /// The library title with this TMDB id, if already added.
    var existing: UUID?

    var id: String { "\(kind.rawValue)-\(tmdbID)" }
}

extension AppServices {
    var libraryReader: RealLibrary {
        RealLibrary(
            database: database, repo: library, watchStates: watchStates, torrents: torrents, monitor: monitor,
            tmdb: { [weak self] in await self?.tmdb() })
    }

    /// Searches TMDB for movies and shows. Throws a `MetadataError` (plain language) on failure.
    func searchCatalogue(_ query: String) async throws -> [CatalogueResult] {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        let page = try await client.search(query)
        let existing = try await library.titles(matching: MarqueeCore.LibraryFilter())
        func existingID(_ kind: TitleKind, _ tmdb: Int) -> UUID? {
            existing.first { $0.kind == kind && $0.tmdbId == tmdb }?.id
        }
        func year(_ date: Date?) -> Int? { date.map { Calendar(identifier: .gregorian).component(.year, from: $0) } }
        return page.results.compactMap { result -> CatalogueResult? in
            switch result {
            case .movie(let m):
                return CatalogueResult(
                    kind: .movie, tmdbID: m.id, title: m.title, year: year(m.releaseDate), overview: m.overview ?? "",
                    posterURL: m.posterPath?.url(size: .w185), existing: existingID(.movie, m.id))
            case .series(let s):
                return CatalogueResult(
                    kind: .series, tmdbID: s.id, title: s.name, year: year(s.firstAirDate), overview: s.overview ?? "",
                    posterURL: s.posterPath?.url(size: .w185), existing: existingID(.series, s.id))
            case .person:
                return nil
            }
        }
    }

    /// Adds a title with its seasons and episodes (from TMDB) using `preset`. Throws
    /// `LibraryError.alreadyInLibrary` for a duplicate.
    @discardableResult
    func addToLibrary(_ result: CatalogueResult, preset: QualityProfileConfig) async throws -> Title {
        guard let client = tmdb() else { throw MetadataError.invalidAPIKey }
        try await database.ensurePresetProfiles()
        let calendar = Calendar(identifier: .gregorian)
        let added: Title
        switch result.kind {
        case .movie:
            let d = try await client.movieDetails(id: result.tmdbID)
            added = try await library.add(
                Title(
                    kind: .movie, tmdbId: d.id, imdbId: d.imdbID, title: d.title,
                    year: d.releaseDate.map { calendar.component(.year, from: $0) }, overview: d.overview,
                    status: d.status, qualityProfileId: preset.id, posterPath: d.posterPath?.path,
                    backdropPath: d.backdropPath?.path),
                seasons: [])
        case .series:
            let d = try await client.seriesDetails(id: result.tmdbID)
            var drafts: [SeasonDraft] = []
            await withTaskGroup(of: SeasonDraft.self) { group in
                for season in d.seasons {
                    group.addTask {
                        let monitored = season.seasonNumber > 0
                        guard let details = try? await client.seasonDetails(seriesID: d.id, season: season.seasonNumber) else {
                            return SeasonDraft(seasonNumber: season.seasonNumber, monitored: monitored)
                        }
                        return RealLibrary.draft(details, monitored: monitored)
                    }
                }
                for await draft in group { drafts.append(draft) }
            }
            drafts.sort { $0.seasonNumber < $1.seasonNumber }
            added = try await library.add(
                Title(
                    kind: .series, tmdbId: d.id, tvdbId: d.tvdbID, imdbId: d.imdbID, title: d.name,
                    year: d.firstAirDate.map { calendar.component(.year, from: $0) }, overview: d.overview,
                    status: d.status, qualityProfileId: preset.id, posterPath: d.posterPath?.path,
                    backdropPath: d.backdropPath?.path),
                seasons: drafts)
        }
        try? await history.append(HistoryEvent(
            type: .titleAdded, entityType: .title, entityUUID: added.id, titleId: added.id,
            payload: ["preset": .string(preset.name)]))
        libraryChanged()
        return added
    }
}
