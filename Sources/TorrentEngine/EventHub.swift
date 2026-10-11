import CTorrentShim
import Foundation
import Synchronization

/// Fan-out of libtorrent events to any number of `AsyncStream` subscribers.
///
/// `publish` runs on the shim's dedicated alert thread; everything else may run anywhere, so state
/// is guarded by a mutex. Streams are unbounded and cost nothing while no event is flowing.
final class EventHub: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<TorrentEvent>.Continuation] = [:]
        var listenPorts: [ListenKind: Int] = [:]
    }

    private let state = Mutex(State())

    func subscribe() -> AsyncStream<TorrentEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TorrentEvent>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func listenPort(_ kind: ListenKind) -> Int? {
        state.withLock { $0.listenPorts[kind] }
    }

    func publish(_ event: TorrentEvent) {
        let targets: [AsyncStream<TorrentEvent>.Continuation] = state.withLock { state in
            if case let .listening(port, _, kind) = event { state.listenPorts[kind] = port }
            return Array(state.subscribers.values)
        }
        for target in targets { target.yield(event) }
    }

    func finishAll() {
        let targets = state.withLock { state in
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for target in targets { target.finish() }
    }
}

extension TorrentEvent {
    /// Translates a shim event. Only valid inside the callback (pointers are borrowed).
    init?(_ event: UnsafePointer<mq_event>) {
        let e = event.pointee
        let id = e.torrent_id.map { TorrentID(hex: String(cString: $0)) }
        let message = e.message.map { String(cString: $0) } ?? ""
        let piece = Int(e.piece)
        let value = Int(e.value)
        let data = e.data.map { Data(bytes: $0, count: e.data_len) } ?? Data()
        let kind = ListenKind(rawValue: e.flags) ?? .other

        let type = mq_event_type(rawValue: UInt32(bitPattern: e.type))
        switch type {
        case MQ_EVENT_LISTEN_SUCCEEDED: self = .listening(port: value, address: message, kind: kind)
        case MQ_EVENT_LISTEN_FAILED: self = .listenFailed(port: value, message: message, kind: kind)
        default:
            guard let id else { return nil }
            switch type {
            case MQ_EVENT_TORRENT_REMOVED:
                self = .removed(id, reason: TorrentRemovalReason(rawValue: Int32(value)) ?? .byEngine)
            case MQ_EVENT_METADATA_RECEIVED: self = .metadataReceived(id)
            case MQ_EVENT_METADATA_FAILED: self = .metadataFailed(id, message: message)
            case MQ_EVENT_TORRENT_CHECKED: self = .checked(id)
            case MQ_EVENT_STATE_CHANGED:
                guard let state = TorrentState(rawValue: Int32(value)) else { return nil }
                self = .stateChanged(id, state)
            case MQ_EVENT_PIECE_FINISHED: self = .pieceFinished(id, piece: piece)
            case MQ_EVENT_HASH_FAILED: self = .hashFailed(id, piece: piece)
            case MQ_EVENT_FILE_COMPLETED: self = .fileCompleted(id, file: value)
            case MQ_EVENT_TORRENT_FINISHED: self = .finished(id)
            case MQ_EVENT_TORRENT_PAUSED: self = .paused(id)
            case MQ_EVENT_TORRENT_RESUMED: self = .resumed(id)
            case MQ_EVENT_TORRENT_ERROR: self = .error(id, message: message)
            case MQ_EVENT_FILE_ERROR: self = .fileError(id, file: value, message: message)
            case MQ_EVENT_PIECE_READ: self = .pieceRead(id, piece: piece, data: data)
            case MQ_EVENT_PIECE_READ_FAILED: self = .pieceReadFailed(id, piece: piece, message: message)
            case MQ_EVENT_RESUME_DATA: self = .resumeData(id, data)
            case MQ_EVENT_RESUME_DATA_FAILED: self = .resumeDataFailed(id, message: message)
            default: return nil
            }
        }
    }
}
