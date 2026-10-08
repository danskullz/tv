import Foundation
import GRDB
import Testing

@testable import MarqueeCore

@Suite struct PersistenceLibraryTests {
    let database: AppDatabase
    let library: GRDBLibraryRepository

    init() throws {
        database = try AppDatabase.inMemory()
        library = GRDBLibraryRepository(database)
    }

    static func series(_ name: String = "The Office", tmdb: Int? = 2316) -> Title {
        Title(kind: .series, tmdbId: tmdb, title: name, year: 2005, overview: "A mockumentary.")
    }

    @Test func addsTitleWithSeasonsAndEpisodes() async throws {
        let t = Self.series()
        try await library.add(
            t,
            seasons: [
                SeasonDraft(
                    seasonNumber: 1,
                    episodes: (1...6).map { EpisodeDraft(episodeNumber: $0, absoluteNumber: $0) }),
                SeasonDraft(seasonNumber: 2, monitored: false, episodes: [EpisodeDraft(episodeNumber: 1, monitored: false)]),
            ])
        let fetched = try #require(try await library.title(id: t.id))
        #expect(fetched.title == "The Office")
        #expect(fetched.sortTitle == "office")
        #expect(fetched.seriesType == .standard)
        #expect(fetched.monitorMode == .all)
        let seasons = try await library.seasons(titleId: t.id)
        #expect(seasons.map(\.seasonNumber) == [1, 2])
        #expect(seasons[1].monitored == false)
        let episodes = try await library.episodes(titleId: t.id)
        #expect(episodes.count == 7)
        #expect(episodes.first?.episodeNumber == 1 && episodes.last?.seasonNumber == 2)
        try await library.setEpisodeMonitored(episodes[0].id, false)
        #expect(try await library.episodes(titleId: t.id)[0].monitored == false)
    }

    @Test func rejectsDuplicateLiveTitle() async throws {
        let first = Self.series()
        try await library.add(first, seasons: [])
        await #expect(throws: LibraryError.alreadyInLibrary(existing: first.id)) {
            try await library.add(Self.series("Dup"), seasons: [])
        }
        // A movie with the same tmdb id is a different title.
        try await library.add(Title(kind: .movie, tmdbId: 2316, title: "Movie"), seasons: [])
    }

    @Test func listFiltersAndSorts() async throws {
        try await library.add(Self.series("Beta", tmdb: 1), seasons: [])
        try await library.add(Self.series("Alpha", tmdb: 2), seasons: [])
        var anime = Title(kind: .series, tmdbId: 3, title: "Gamma", seriesType: .anime)
        anime.monitored = false
        try await library.add(anime, seasons: [])
        try await library.add(Title(kind: .movie, tmdbId: 4, title: "Delta"), seasons: [])

        #expect(try await library.titles(matching: .init()).map(\.title) == ["Alpha", "Beta", "Delta", "Gamma"])
        #expect(try await library.titles(matching: .init(kind: .movie)).map(\.title) == ["Delta"])
        #expect(try await library.titles(matching: .init(seriesType: .anime)).map(\.title) == ["Gamma"])
        #expect(try await library.titles(matching: .init(monitored: false)).map(\.title) == ["Gamma"])
        #expect(try await library.titles(matching: .init(limit: 2)).count == 2)
    }

    @Test func softDeleteAndRestore() async throws {
        let t = Self.series()
        try await library.add(t, seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1)])])
        try await library.softDelete(titleId: t.id)

        #expect(try await library.titles(matching: .init()).isEmpty)
        #expect(try await library.titles(matching: .init(deleted: .only)).map(\.id) == [t.id])
        #expect(try await library.searchLibrary(query: "office", limit: 10).isEmpty)
        #expect(try await library.episodes(titleId: t.id).count == 1)  // children kept

        try await library.restore(titleId: t.id)
        #expect(try await library.titles(matching: .init()).map(\.id) == [t.id])
        #expect(try await library.title(id: t.id)?.deletedAt == nil)
        #expect(try await library.searchLibrary(query: "office", limit: 10).count == 1)
    }

    @Test func restoreFailsWhenDuplicateAddedMeanwhile() async throws {
        let old = Self.series()
        try await library.add(old, seasons: [])
        try await library.softDelete(titleId: old.id)
        let replacement = Self.series("Office Again")
        try await library.add(replacement, seasons: [])
        await #expect(throws: LibraryError.alreadyInLibrary(existing: replacement.id)) {
            try await library.restore(titleId: old.id)
        }
    }

    @Test func softDeleteUnknownTitleThrows() async {
        let id = UUID()
        await #expect(throws: LibraryError.notFound(id)) { try await library.softDelete(titleId: id) }
    }

    @Test func purgeRemovesOnlyOldDeletedTitlesAndCascades() async throws {
        let gone = Self.series("Gone", tmdb: 1)
        let kept = Self.series("Kept", tmdb: 2)
        try await library.add(gone, seasons: [SeasonDraft(seasonNumber: 1, episodes: [EpisodeDraft(episodeNumber: 1)])])
        try await library.add(kept, seasons: [])
        try await library.softDelete(titleId: gone.id)
        #expect(try await library.purgeDeleted(before: Date().addingTimeInterval(-60)) == 0)
        #expect(try await library.purgeDeleted(before: Date().addingTimeInterval(60)) == 1)
        #expect(try await library.title(id: gone.id) == nil)
        #expect(try await library.episodes(titleId: gone.id).isEmpty)
        #expect(try await library.title(id: kept.id) != nil)
        #expect(try await database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM titleSearch") } == 1)
    }

    @Test func searchMatchesPrefixesAcrossColumnsAndTracksUpdates() async throws {
        var t = Title(kind: .movie, tmdbId: 1, title: "Interstellar", overview: "Explorers travel through a wormhole")
        try await library.add(t, seasons: [])
        try await library.add(Title(kind: .movie, tmdbId: 2, title: "Inception"), seasons: [])

        #expect(try await library.searchLibrary(query: "inter", limit: 10).map(\.title) == ["Interstellar"])
        #expect(try await library.searchLibrary(query: "in", limit: 10).count == 2)
        #expect(try await library.searchLibrary(query: "worm", limit: 10).map(\.title) == ["Interstellar"])
        #expect(try await library.searchLibrary(query: "  ", limit: 10).isEmpty)
        #expect(try await library.searchLibrary(query: "\"(*", limit: 10).isEmpty)  // no crash on junk
        #expect(try await library.searchLibrary(query: "ÎNTER", limit: 10).count == 1)  // diacritics/case

        t.title = "Arrival"
        t.sortTitle = "arrival"
        try await library.save(t)
        #expect(try await library.searchLibrary(query: "inter", limit: 10).isEmpty)
        #expect(try await library.searchLibrary(query: "arri", limit: 10).count == 1)
    }

    @Test func observationEmitsInitialAndChangedValues() async throws {
        var iterator = library.observeTitles(matching: .init()).makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.isEmpty == true)

        let t = Self.series()
        try await library.add(t, seasons: [])
        var latest = await iterator.next()
        #expect(latest?.map(\.id) == [t.id])

        try await library.softDelete(titleId: t.id)
        latest = await iterator.next()
        #expect(latest?.isEmpty == true)
    }
}
