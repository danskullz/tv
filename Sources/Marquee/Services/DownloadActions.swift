import Foundation
import GRDB
import MarqueeCore
import MarqueeEngine

extension AppServices {
    func monitorTitle(_ titleID: UUID) async throws {
        try await database.writer.write { db in
            guard var title = try Title.fetchOne(db, key: titleID) else { throw LibraryError.notFound(titleID) }
            title.monitored = true
            title.monitorMode = title.kind == .movie ? .movieOnly : .all
            title.updatedAt = Date()
            try title.update(db)
            if title.kind == .series {
                let now = Date()
                try db.execute(sql: "UPDATE season SET monitored = 1, updatedAt = ? WHERE titleId = ?", arguments: [now, titleID])
                try db.execute(sql: "UPDATE episode SET monitored = 1, updatedAt = ? WHERE titleId = ?", arguments: [now, titleID])
            }
        }
        libraryChanged()
        try await startAutomaticReleaseAutomation()
    }

    func downloadNow(titleID: UUID) async throws -> AutomationRunResult {
        guard let title = try await library.title(id: titleID) else { throw LibraryError.notFound(titleID) }
        if !title.monitored { try await monitorTitle(titleID) }
        let targets = try await automationTargets(titleID: titleID)
        guard let target = targets.first else { return AutomationRunResult() }
        try await startAutomaticReleaseAutomation()
        return await searchNow(target) ?? AutomationRunResult()
    }

    func startAutomaticReleaseAutomation() async throws {
        try await startReleaseAutomation { [weak self] in
            guard let self else { return [] }
            return try await self.automationTargets()
        }
    }

    func automationTargets(titleID: UUID? = nil) async throws -> [AutomationTarget] {
        let titles = try await library.titles(matching: MarqueeCore.LibraryFilter(monitored: true))
        let eligible = titles.filter { titleID == nil || $0.id == titleID }
        var targets: [AutomationTarget] = []
        for title in eligible where title.deletedAt == nil {
            let episodes = title.kind == MarqueeCore.TitleKind.series ? try await library.episodes(titleId: title.id) : []
            let files = try await database.writer.read {
                try MediaFile.filter(Column("titleId") == title.id).fetchAll($0)
            }
            var fileEpisodeIDs = Set<UUID>()
            var currentFiles: [UUID: CurrentFile] = [:]
            for file in files {
                let linked = try await database.writer.read { db in
                    try UUID.fetchAll(
                        db, sql: "SELECT episodeId FROM mediaFileEpisode WHERE mediaFileId = ?",
                        arguments: [file.id])
                }
                fileEpisodeIDs.formUnion(linked)
                var parsed = ReleaseParser.parse(file.qualityName ?? "")
                if let resolution = file.resolution, let value = Resolution(rawValue: resolution) { parsed.resolution = value }
                if let source = file.source, let value = Source(rawValue: source) { parsed.source = value }
                if let codec = file.videoCodec, let value = VideoCodec(rawValue: codec) { parsed.videoCodec = value }
                let current = CurrentFile(tier: QualityTier.derive(from: parsed), formatScore: file.customFormatScore ?? 0)
                for episodeID in linked { currentFiles[episodeID] = current }
                if title.kind == MarqueeCore.TitleKind.movie { currentFiles[title.id] = current }
            }

            let profile: QualityProfileConfig
            if let profileID = title.qualityProfileId,
                let record = try await database.writer.read({ try QualityProfile.fetchOne($0, key: profileID) })
            {
                profile = QualityProfileConfig(record: record)
            } else {
                profile = AppSettings.defaultPreset
            }
            let missing = WantedQuery.missing(
                title: title, episodes: episodes, fileEpisodeIDs: fileEpisodeIDs,
                hasMovieFile: title.kind == MarqueeCore.TitleKind.movie && !files.isEmpty)
            let upgrades = WantedQuery.cutoffUnmet(
                title: title, episodes: episodes, currentFiles: currentFiles, profile: profile)
            for wanted in missing + upgrades {
                targets.append(AutomationTarget(
                    wanted: wanted, profile: profile, formats: BuiltInFormats.all,
                    savePath: downloadFolder, minimumSeeders: 1))
            }
        }
        return targets
    }
}
