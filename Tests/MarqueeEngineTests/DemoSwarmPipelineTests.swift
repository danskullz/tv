import Foundation
import MarqueeCore
import Testing
import TorrentEngine

@testable import MarqueeEngine

/// Drives the whole add -> search -> grab -> stream path with no UI and no outside sources: the demo
/// harness's fake Torznab indexer (real HTTP on loopback), its loopback seeder, a real torrent session,
/// the real stream controller and server. Asserts the URL it returns serves the seeded bytes.
@Suite("Demo swarm end to end", .serialized)
struct DemoSwarmPipelineTests {
    /// A committed 3 s clip: CI virtual machines have no video encoder, so tests never encode.
    private static let fixtureClip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MarqueePlayerTests/Fixtures/test-clip.mp4")

    private struct World: @unchecked Sendable {
        let scratch: EngineScratch
        let swarm: DemoSwarm
        let database: AppDatabase
        let series: Title
        let movie: Title
        let pipeline: PlayPipeline
        let leecher: TorrentSession
        let server: StreamServer
    }

    private func makeWorld(includeDead: Bool) async throws -> World {
        let scratch = try EngineScratch()
        let swarm = try await DemoSwarm.start(
            directory: try scratch.directory("demo"),
            options: .init(includeDeadRelease: includeDead, clipSource: .file(Self.fixtureClip)))
        let database = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        let (series, movie) = try await swarm.install(into: database, secrets: secrets)

        let coordinator = IndexerSearchCoordinator(secrets: secrets)
        let definitions = try await GRDBIndexerRepository(database).all().compactMap(\.definition)
        await coordinator.setIndexers(definitions.map { var d = $0; d.rateLimit = .unlimited; return d })

        let leecher = try await engineMakeLeecher()
        let server = StreamServer()
        let downloads = try scratch.directory("downloads")
        let factory = SessionControllerFactory(session: leecher, server: server) {
            StreamControllerConfiguration(savePath: downloads, metadataTimeout: .seconds(3), stallTimeout: .seconds(20))
        }
        let pipeline = PlayPipeline(
            search: CoordinatorSearcher(coordinator), controllers: factory, grabs: GRDBGrabRepository(database),
            blocklist: GRDBBlocklistRepository(database), history: GRDBHistoryRepository(database),
            configuration: { PlayPipelineConfiguration(readyTimeout: .seconds(30)) })
        return World(
            scratch: scratch, swarm: swarm, database: database, series: series, movie: movie, pipeline: pipeline,
            leecher: leecher, server: server)
    }

    private func withWorld(includeDead: Bool, _ body: (World) async throws -> Void) async throws {
        let world = try await makeWorld(includeDead: includeDead)
        do { try await body(world) } catch {
            await shutdown(world)
            throw error
        }
        await shutdown(world)
    }

    private func shutdown(_ world: World) async {
        await world.server.stop()
        await world.leecher.shutdown()
        await world.swarm.stop()
    }

    private func request(_ world: World, scope: PlayScope) async throws -> PlayRequest {
        let episodes = try await GRDBLibraryRepository(world.database).episodes(titleId: world.series.id)
        return PlayRequest(
            title: PlayTitle(
                id: world.series.id, kind: .series, name: world.series.title, year: 2026, tvdbID: DemoSwarm.seriesTVDBID),
            scope: scope, profile: .balanced,
            episodes: episodes.map { PackEpisode(ref: EpisodeRef(season: $0.seasonNumber, episode: $0.episodeNumber)) })
    }

    @Test("plays an episode: dead top release fails over to the healthy one, bytes match the seeded file")
    func episodeWithFailover() async throws {
        try await withWorld(includeDead: true) { world in

            let op = world.pipeline.begin(try await request(world, scope: .episode(EpisodeRef(season: 1, episode: 1))))
            let statuses = Task { var all: [String] = []; for await s in op.statuses { all.append(s.message) }; return all }
            let stream = try await op.stream()
            let messages = await statuses.value

            #expect(stream.release.title.hasSuffix("DEMO"), "fell over from the dead 1080p release to \(stream.release.title)")
            #expect(messages.contains { $0.hasPrefix("Searching 1 indexer") })
            #expect(messages.contains { $0.contains("picked 1080p WEB-DL (300 seeders)") }, "\(messages)")
            #expect(messages.contains { $0.contains("Trying the next best release") })
            #expect(messages.last == "Ready to play")
            let blocked = try await GRDBBlocklistRepository(world.database).entries(titleId: world.series.id)
            #expect(blocked.map(\.releaseTitle) == ["Marquee.Test.Pattern.S01E01.1080p.WEB-DL.H264-DEAD"])

            let expected = try Data(contentsOf: world.swarm.episodeFiles[0])
            let http = engineSession()
            let whole = try await engineFetch(stream.url, session: http)
            #expect(whole.status == 200)
            #expect(whole.data == expected)
            let range = try await engineFetch(stream.url, range: 100..<2100, session: http)
            #expect(range.status == 206)
            #expect(range.data == expected.subdata(in: 100..<2100))

            // The decision log can answer "Why this release?".
            let grabs = try await GRDBGrabRepository(world.database).grabs(titleId: world.series.id, limit: 10)
            #expect(grabs.count == 2)
            #expect(grabs.first { $0.id == stream.release.grabID }?.outcome == .grabbed)
            await stream.control.stop(removeTorrent: true)
        }
    }

    @Test("plays a season from episode 2 out of the pack, then advances to episode 3")
    func seasonPack() async throws {
        try await withWorld(includeDead: false) { world in

            let scope = PlayScope.season(1, startingAt: EpisodeRef(season: 1, episode: 2))
            let stream = try await world.pipeline.begin(try await request(world, scope: scope)).stream()
            #expect(stream.release.isPack)
            #expect(stream.release.title == "Marquee.Test.Pattern.S01.720p.WEB-DL.H264-DEMO")
            #expect(stream.episodes == [EpisodeRef(season: 1, episode: 2)])

            let http = engineSession()
            let second = try await engineFetch(stream.url, session: http)
            #expect(second.data == (try Data(contentsOf: world.swarm.episodeFiles[1])))

            let next = try await stream.control.advance(to: EpisodeRef(season: 1, episode: 3))
            #expect(next.episodes == [EpisodeRef(season: 1, episode: 3)])
            let third = try await engineFetch(next.url, session: http)
            #expect(third.data == (try Data(contentsOf: world.swarm.episodeFiles[2])))
            await stream.control.stop(removeTorrent: true)
        }
    }

    @Test("plays the demo movie")
    func movie() async throws {
        try await withWorld(includeDead: false) { world in

            let request = PlayRequest(
                title: PlayTitle(
                    id: world.movie.id, kind: .movie, name: world.movie.title, year: 2026, tmdbID: DemoSwarm.movieTMDBID),
                scope: .movie, profile: .balanced)
            let stream = try await world.pipeline.begin(request).stream()
            #expect(stream.release.title == "Marquee.Demo.Reel.2026.720p.WEB-DL.H264-DEMO")
            let data = try await engineFetch(stream.url, session: engineSession())
            #expect(data.data == (try Data(contentsOf: world.swarm.movieFile)))
            await stream.control.stop(removeTorrent: true)
        }
    }

    @Test("the fake indexer sees id queries first")
    func indexerQueries() async throws {
        try await withWorld(includeDead: false) { world in
            let stream = try await world.pipeline.begin(try await request(world, scope: .episode(EpisodeRef(season: 1, episode: 1)))).stream()
            let searches = world.swarm.indexerRequests.filter { $0.contains("t=tvsearch") }
            #expect(searches.first?.contains("tvdbid=99000001") == true && searches.first?.contains("ep=1") == true, "\(searches)")
            await stream.control.stop(removeTorrent: true)
        }
    }
}
