import CTorrentShim
import Foundation
import Synchronization
import Testing

@testable import TorrentEngine

/// Collects `MQ_EVENT_TORRENT_REMOVED` payloads. Runs on the shim's alert thread.
fileprivate final class RemovalCollector: @unchecked Sendable {
    private let state = Mutex<[(id: String, reason: Int32)]>([])
    func record(_ id: String, _ reason: Int32) { state.withLock { $0.append((id, reason)) } }
    var removals: [(id: String, reason: Int32)] { state.withLock { $0 } }
}

private func collectRemoval(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<mq_event>?) {
    guard let event, let context,
        mq_event_type(rawValue: UInt32(bitPattern: event.pointee.type)) == MQ_EVENT_TORRENT_REMOVED,
        let id = event.pointee.torrent_id
    else { return }
    Unmanaged<RemovalCollector>.fromOpaque(context).takeUnretainedValue().record(String(cString: id), event.pointee.value)
}

/// Removal bookkeeping, driven through the C API.
///
/// These behaviours are only observable while a removal is still in flight, which is exactly the
/// window `TorrentSession.remove(_:deleteFiles:)` now waits out — so they cannot be reached
/// through the Swift wrapper without a test hook in production code.
@Suite("TorrentEngine removal reasons", .serialized)
struct RemovalReasonTests {
    struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    fileprivate final class Harness {
        let session: OpaquePointer
        let directory: URL
        let collector: RemovalCollector
        private let context: UnsafeMutableRawPointer

        init() throws {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-removal-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            directory = scratch
            let collector = RemovalCollector()
            self.collector = collector
            context = Unmanaged.passRetained(collector).toOpaque()
            var error: UnsafeMutablePointer<CChar>?
            let contextValue = context
            let created = "127.0.0.1:0".withCString { listen in
                var config = mq_session_config(
                    listen_interfaces: listen, outgoing_interfaces: nil, user_agent: nil,
                    enable_dht: 0, enable_lsd: 0, enable_upnp: 0, enable_natpmp: 0, encryption_mode: 0)
                return mq_session_create(&config, collectRemoval, contextValue, &error)
            }
            guard let created else {
                let message = error.map { String(cString: $0) } ?? "could not create session"
                mq_free(error)
                throw TestError(message)
            }
            session = created
        }

        deinit {
            mq_session_destroy(session)
            Unmanaged<RemovalCollector>.fromOpaque(context).release()
            try? FileManager.default.removeItem(at: directory)
        }

        /// A one-file `.torrent`, built through the shim so the test needs no fixture on disk.
        func torrentData() throws -> Data {
            let file = directory.appendingPathComponent("payload.bin")
            try Data(repeating: 0xA5, count: 128 * 1024).write(to: file)
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            var error: UnsafeMutablePointer<CChar>?
            let code = mq_create_torrent(file.path, 16 * 1024, &bytes, &count, &error)
            guard code == MQ_OK, let bytes else {
                let message = error.map { String(cString: $0) } ?? "could not create torrent"
                mq_free(error)
                throw TestError(message)
            }
            defer { mq_free(bytes) }
            return Data(bytes: bytes, count: count)
        }

        @discardableResult
        func add(_ torrent: Data) throws -> String {
            var id = [CChar](repeating: 0, count: 41)
            var error: UnsafeMutablePointer<CChar>?
            let code = torrent.withUnsafeBytes { raw in
                mq_session_add_torrent_data(
                    session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, directory.path, 0, nil, 0,
                    &id, &error)
            }
            guard code == MQ_OK else {
                let message = error.map { String(cString: $0) } ?? "add failed (\(code))"
                mq_free(error)
                throw TestError(message)
            }
            return String(decoding: id.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        /// Raw `mq_session_add_torrent_data`, so the caller can assert on a refusal. Records the id a
        /// successful add reported.
        func addExpectingFailure(_ torrent: Data) -> Int32 {
            var id = [CChar](repeating: 0, count: 41)
            var error: UnsafeMutablePointer<CChar>?
            let code = torrent.withUnsafeBytes { raw in
                mq_session_add_torrent_data(
                    session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, directory.path, 0, nil, 0,
                    &id, &error)
            }
            mq_free(error)
            if code == MQ_OK {
                addedID.withLock { $0 = String(cString: id) }
            }
            return code
        }

        let addedID = Mutex<String?>(nil)

        func remove(_ id: String) -> Int32 { mq_torrent_remove(session, id, 1) }

        func waitForRemoval(timeout: Duration = .seconds(10)) async throws -> (id: String, reason: Int32) {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let first = collector.removals.first { return first }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TestError("no removal was reported within \(timeout)")
        }
    }

    @Test("a removal Marquee asked for is reported as ours, not as the engine acting on its own")
    func removalWeRequestedCarriesOurReason() async throws {
        let harness = try Harness()
        let id = try harness.add(try harness.torrentData())
        #expect(harness.remove(id) == MQ_OK)

        let removal = try await harness.waitForRemoval()
        #expect(removal.id == id)
        #expect(mq_remove_reason(rawValue: UInt32(removal.reason)) == MQ_REMOVED_BY_SHIM_DELETING)
    }

    @Test("re-adding the same download never leaves a torrent that then vanishes")
    func reAddAroundRemovalNeverYieldsADyingTorrent() async throws {
        // `remove_torrent` only posts a job, so whether the removal has landed by the time the next
        // add happens is a genuine race and cannot be forced from outside without parking the
        // shim's alert thread — which deadlocks `mq_session_destroy`. So assert the guarantee
        // instead of the mechanism: refused while the removal is in flight, or a fresh live torrent
        // once it is gone. Being handed the dying torrent, and watching it disappear, is the bug.
        for _ in 1...12 {
            let harness = try Harness()
            let torrent = try harness.torrentData()
            let id = try harness.add(torrent)
            #expect(harness.remove(id) == MQ_OK)

            let code = harness.addExpectingFailure(torrent)
            if code == MQ_ERR_DUPLICATE { continue }
            #expect(code == MQ_OK, "the add failed for an unexpected reason (\(code))")

            let added = try #require(harness.addedID.withLock { $0 }, "an accepted add reports its torrent")
            try await Task.sleep(for: .milliseconds(300))

            var status = mq_torrent_status()
            #expect(
                mq_torrent_get_status(harness.session, added, &status) == MQ_OK,
                "the replacement is not in the session: it was the dying torrent"
            )
            #expect(
                harness.collector.removals.count <= 1,
                "the replacement was removed too: \(harness.collector.removals)"
            )
        }
    }

    @Test("the Swift event decodes every reason the shim can report")
    func removalReasonsDecode() {
        let hex = String(repeating: "a", count: 40)
        let id = TorrentID(hex: hex)
        let expected: [(mq_remove_reason, TorrentRemovalReason)] = [
            (MQ_REMOVED_BY_ENGINE, .byEngine),
            (MQ_REMOVED_BY_SHIM, .requestedByApp),
            (MQ_REMOVED_BY_SHIM_DELETING, .requestedByAppDeletingFiles),
        ]
        for (raw, reason) in expected {
            let decoded = hex.withCString { cString -> TorrentEvent? in
                var event = mq_event()
                event.type = Int32(MQ_EVENT_TORRENT_REMOVED.rawValue)
                event.torrent_id = cString
                event.piece = -1
                event.value = Int32(raw.rawValue)
                return withUnsafePointer(to: &event) { TorrentEvent($0) }
            }
            guard case let .removed(decodedID, decodedReason) = decoded else {
                Issue.record("MQ_EVENT_TORRENT_REMOVED (\(raw)) did not decode")
                continue
            }
            #expect(decodedID == id)
            #expect(decodedReason == reason)
        }
    }
}