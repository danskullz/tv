import Foundation
import GRDB

public struct EpisodeDraft: Sendable {
    public var episodeNumber: Int
    public var absoluteNumber: Int?
    public var airDate: Date?
    public var title: String?
    public var runtime: Int?
    public var tvdbId: Int?
    public var monitored: Bool

    public init(
        episodeNumber: Int, absoluteNumber: Int? = nil, airDate: Date? = nil, title: String? = nil,
        runtime: Int? = nil, tvdbId: Int? = nil, monitored: Bool = true
    ) {
        self.episodeNumber = episodeNumber
        self.absoluteNumber = absoluteNumber
        self.airDate = airDate
        self.title = title
        self.runtime = runtime
        self.tvdbId = tvdbId
        self.monitored = monitored
    }
}

public struct SeasonDraft: Sendable {
    public var seasonNumber: Int
    public var monitored: Bool
    public var episodes: [EpisodeDraft]

    public init(seasonNumber: Int, monitored: Bool = true, episodes: [EpisodeDraft] = []) {
        self.seasonNumber = seasonNumber
        self.monitored = monitored
        self.episodes = episodes
    }
}

public enum LibraryError: Error, Equatable {
    case notFound(UUID)
    /// A live title with the same tmdb/tvdb id exists.
    case alreadyInLibrary(existing: UUID)
}

public enum LibrarySort: Sendable {
    case sortTitle, recentlyAdded, year
}

public struct LibraryFilter: Sendable, Equatable {
    public enum Deleted: Sendable { case exclude, include, only }

    public var kind: TitleKind?
    public var seriesType: SeriesType?
    public var monitored: Bool?
    public var deleted: Deleted
    public var sort: LibrarySort
    public var limit: Int?

    public init(
        kind: TitleKind? = nil, seriesType: SeriesType? = nil, monitored: Bool? = nil,
        deleted: Deleted = .exclude, sort: LibrarySort = .sortTitle, limit: Int? = nil
    ) {
        self.kind = kind
        self.seriesType = seriesType
        self.monitored = monitored
        self.deleted = deleted
        self.sort = sort
        self.limit = limit
    }
}

public protocol LibraryRepository: Sendable {
    /// Inserts a title with its seasons and episodes in one transaction.
    @discardableResult
    func add(_ title: Title, seasons: [SeasonDraft]) async throws -> Title
    func title(id: UUID) async throws -> Title?
    func titles(matching filter: LibraryFilter) async throws -> [Title]
    func seasons(titleId: UUID) async throws -> [Season]
    func episodes(titleId: UUID) async throws -> [Episode]
    func save(_ title: Title) async throws
    func setEpisodeMonitored(_ episodeId: UUID, _ monitored: Bool) async throws

    /// Prefix-matching full-text search over title, sort title and overview (live titles only).
    func searchLibrary(query: String, limit: Int) async throws -> [Title]

    /// Hides the title (undo window). Children and files are kept.
    func softDelete(titleId: UUID) async throws
    /// Brings a soft-deleted title back; throws `alreadyInLibrary` if a live duplicate was added since.
    func restore(titleId: UUID) async throws
    /// Permanently removes titles soft-deleted before `date`; returns the number removed.
    @discardableResult
    func purgeDeleted(before date: Date) async throws -> Int

    /// Emits the filtered list now and after every change to the tables it reads.
    func observeTitles(matching filter: LibraryFilter) -> AsyncStream<[Title]>
}

public struct GRDBLibraryRepository: LibraryRepository {
    private let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    @discardableResult
    public func add(_ title: Title, seasons: [SeasonDraft]) async throws -> Title {
        try await database.writer.write { db in
            try Self.assertNoLiveDuplicate(of: title, in: db)
            try title.insert(db)
            let now = Date()
            for draft in seasons {
                let season = Season(
                    titleId: title.id, seasonNumber: draft.seasonNumber,
                    monitored: draft.monitored, createdAt: now, updatedAt: now)
                try season.insert(db)
                for e in draft.episodes {
                    try Episode(
                        titleId: title.id, seasonId: season.id, seasonNumber: draft.seasonNumber,
                        episodeNumber: e.episodeNumber, absoluteNumber: e.absoluteNumber,
                        airDate: e.airDate, monitored: e.monitored, title: e.title,
                        runtime: e.runtime, tvdbId: e.tvdbId, createdAt: now, updatedAt: now
                    ).insert(db)
                }
            }
            return title
        }
    }

    public func title(id: UUID) async throws -> Title? {
        try await database.writer.read { try Title.fetchOne($0, key: id) }
    }

    public func titles(matching filter: LibraryFilter) async throws -> [Title] {
        try await database.writer.read { try Self.request(filter).fetchAll($0) }
    }

    public func seasons(titleId: UUID) async throws -> [Season] {
        try await database.writer.read {
            try Season.filter(Column("titleId") == titleId).order(Column("seasonNumber")).fetchAll($0)
        }
    }

    public func episodes(titleId: UUID) async throws -> [Episode] {
        try await database.writer.read {
            try Episode.filter(Column("titleId") == titleId)
                .order(Column("seasonNumber"), Column("episodeNumber")).fetchAll($0)
        }
    }

    public func save(_ title: Title) async throws {
        var title = title
        title.updatedAt = Date()
        try await database.writer.write { [title] in try title.update($0) }
    }

    public func setEpisodeMonitored(_ episodeId: UUID, _ monitored: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE episode SET monitored = ?, updatedAt = ? WHERE id = ?",
                arguments: [monitored, Date(), episodeId])
        }
    }

    public func searchLibrary(query: String, limit: Int = 50) async throws -> [Title] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await database.writer.read { db in
            try Title.fetchAll(
                db,
                sql: """
                    SELECT title.* FROM titleSearch
                    JOIN title ON title.id = titleSearch.titleId
                    WHERE titleSearch MATCH ? AND title.deletedAt IS NULL
                    ORDER BY bm25(titleSearch, 0.0, 10.0, 5.0, 1.0)
                    LIMIT ?
                    """,
                arguments: [pattern, limit])
        }
    }

    public func softDelete(titleId: UUID) async throws {
        try await database.writer.write { db in
            let now = Date()
            try db.execute(
                sql: "UPDATE title SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NULL",
                arguments: [now, now, titleId])
            if db.changesCount == 0, try !Title.exists(db, key: titleId) {
                throw LibraryError.notFound(titleId)
            }
        }
    }

    public func restore(titleId: UUID) async throws {
        try await database.writer.write { db in
            guard var title = try Title.fetchOne(db, key: titleId) else {
                throw LibraryError.notFound(titleId)
            }
            guard title.deletedAt != nil else { return }
            try Self.assertNoLiveDuplicate(of: title, in: db)
            title.deletedAt = nil
            title.updatedAt = Date()
            try title.update(db)
        }
    }

    @discardableResult
    public func purgeDeleted(before date: Date) async throws -> Int {
        try await database.writer.write { db in
            try Title.filter(Column("deletedAt") != nil && Column("deletedAt") < date).deleteAll(db)
        }
    }

    public func observeTitles(matching filter: LibraryFilter) -> AsyncStream<[Title]> {
        database.observe { db in try Self.request(filter).fetchAll(db) }
    }

    // MARK: -

    static func request(_ filter: LibraryFilter) -> QueryInterfaceRequest<Title> {
        var request = Title.all()
        if let kind = filter.kind { request = request.filter(Column("kind") == kind) }
        if let type = filter.seriesType { request = request.filter(Column("seriesType") == type) }
        if let monitored = filter.monitored { request = request.filter(Column("monitored") == monitored) }
        switch filter.deleted {
        case .exclude: request = request.filter(Column("deletedAt") == nil)
        case .only: request = request.filter(Column("deletedAt") != nil)
        case .include: break
        }
        switch filter.sort {
        case .sortTitle: request = request.order(Column("sortTitle"))
        case .recentlyAdded: request = request.order(Column("addedAt").desc)
        case .year: request = request.order(Column("year").desc, Column("sortTitle"))
        }
        if let limit = filter.limit { request = request.limit(limit) }
        return request
    }

    private static func assertNoLiveDuplicate(of title: Title, in db: Database) throws {
        var clauses: [SQLExpression] = []
        if let tmdb = title.tmdbId { clauses.append(Column("tmdbId") == tmdb) }
        if let tvdb = title.tvdbId { clauses.append(Column("tvdbId") == tvdb) }
        guard !clauses.isEmpty else { return }
        let existing = try Title
            .filter(Column("kind") == title.kind && Column("deletedAt") == nil
                && Column("id") != title.id && clauses.joined(operator: .or))
            .fetchOne(db)
        if let existing { throw LibraryError.alreadyInLibrary(existing: existing.id) }
    }
}
