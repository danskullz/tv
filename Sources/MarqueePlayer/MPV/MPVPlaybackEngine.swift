import CMpv
import Foundation
import os

/// `PlaybackEngine` backed by libmpv.
///
/// Event driven: libmpv calls our wakeup callback when it has something to say, and we drain its event
/// queue on a private serial queue. There are no timers and no polling; an idle or paused player costs
/// nothing. Commands are asynchronous (`mpv_command_async`) so a seek into a not-yet-downloaded range
/// never blocks the caller.
public final class MPVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// No video output: decode and clock only. Used by tests and audio-only use.
        public var headless = false
        /// Silent audio output (tests).
        public var nullAudio = false
        /// `auto-safe` picks VideoToolbox on macOS and falls back to software decode.
        public var hwdec = "auto-safe"
        /// Upper bound for the demuxer read-ahead (SCOPE §5.6: < 400 MB while streaming).
        public var maxCacheBytes = 150 * 1024 * 1024
        public var maxBackBufferBytes = 30 * 1024 * 1024
        /// Extra libmpv options applied before initialization (name -> value).
        public var extraOptions: [String: String] = [:]
        public init() {}
    }

    public enum EngineError: Error, CustomStringConvertible {
        case libraryUnavailable(String)
        case initializationFailed(String)
        public var description: String {
            switch self {
            case .libraryUnavailable(let m): "libmpv unavailable: \(m)"
            case .initializationFailed(let m): "libmpv failed to initialize: \(m)"
            }
        }
    }

    // MARK: State

    private struct Facts {
        var hasFile = false
        var fileLoaded = false
        var pause = false
        var coreIdle = true
        var pausedForCache = false
        var eof = false
        var failure: String?
        var lastErrorLog: String?
        var lastEmittedPosition: TimeInterval = -1
        var snapshot = PlaybackSnapshot()
        var closed = false
    }

    let api: MPVLibrary
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.danskullz.marquee.mpv.events", qos: .userInteractive)
    private let facts = OSAllocatedUnfairLock(initialState: Facts())
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    public let events: AsyncStream<PlaybackEvent>
    private var wakeupBox: Unmanaged<WakeupBox>?
    private let renderLock = OSAllocatedUnfairLock<MPVRenderContext?>(initialState: nil)
    /// libmpv's `vo=libmpv` fails permanently for a file that starts loading before a render context
    /// exists, so with a video surface a `load` is held until the surface attaches one.
    private let needsRenderContext: Bool
    private let pendingLoad = OSAllocatedUnfairLock<[String]?>(initialState: nil)

    /// Position changes smaller than this are not reported (≈ 4 Hz while playing at 1x).
    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let positionQuantum: TimeInterval = 0.25

    private final class WakeupBox: @unchecked Sendable {
        weak var engine: MPVPlaybackEngine?
    }

    public var snapshot: PlaybackSnapshot { facts.withLock { $0.snapshot } }

    // MARK: Lifecycle

    public init(configuration: Configuration = Configuration(), library: MPVLibrary? = nil) throws {
        guard let api = library ?? MPVLibrary.shared else {
            throw EngineError.libraryUnavailable(MPVLibrary.searchPaths().joined(separator: ", "))
        }
        self.api = api
        queue.setSpecific(key: Self.queueKey, value: true)
        needsRenderContext = !configuration.headless
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)

        guard let h = api.create() else { throw EngineError.initializationFailed("mpv_create returned nil") }
        handle = h

        func opt(_ name: String, _ value: String) { _ = api.setOptionString(h, name, value) }
        // Behave like a library: no config files, scripts, terminal, or built-in UI.
        opt("config", "no"); opt("load-scripts", "no"); opt("ytdl", "no"); opt("osc", "no"); opt("osd-level", "0")
        opt("input-default-bindings", "no"); opt("input-vo-keyboard", "no"); opt("input-media-keys", "no")
        opt("terminal", "no"); opt("idle", "yes"); opt("keep-open", "yes"); opt("save-position-on-quit", "no")
        opt("sub-auto", "exact"); opt("audio-display", "no"); opt("force-window", "no")
        opt("cache", "yes"); opt("demuxer-max-bytes", String(configuration.maxCacheBytes))
        opt("demuxer-max-back-bytes", String(configuration.maxBackBufferBytes))
        opt("volume-max", "100"); opt("hwdec", configuration.hwdec)
        opt("vo", configuration.headless ? "null" : "libmpv")
        if configuration.headless || configuration.nullAudio { opt("ao", "null") }
        for (k, v) in configuration.extraOptions { opt(k, v) }

        let status = api.initialize(h)
        guard status >= 0 else {
            api.terminateDestroy(h)
            handle = nil
            throw EngineError.initializationFailed(api.message(for: status))
        }

        _ = api.requestLogMessages(h, "error")
        for name in Self.observed { _ = api.observeProperty(h, 0, name, Self.format(of: name)) }

        let box = WakeupBox()
        box.engine = self
        let unmanaged = Unmanaged.passRetained(box)
        wakeupBox = unmanaged
        api.setWakeupCallback(h, { ctx in
            guard let ctx else { return }
            let box = Unmanaged<WakeupBox>.fromOpaque(ctx).takeUnretainedValue()
            guard let engine = box.engine else { return }
            engine.queue.async { engine.drainEvents() }
        }, unmanaged.toOpaque())
        // Pick up anything queued before the callback was installed.
        queue.async { [weak self] in self?.drainEvents() }
    }

    deinit { shutdown() }

    public func shutdown() {
        let alreadyClosed = facts.withLock { f -> Bool in
            let was = f.closed; f.closed = true; return was
        }
        guard !alreadyClosed, let h = handle else { return }
        renderLock.withLock { ctx in ctx?.free(); ctx = nil }
        api.setWakeupCallback(h, nil, nil)
        // Wait out a drain that is mid-flight (unless we *are* on the queue), then destroy.
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
        api.terminateDestroy(h)
        handle = nil
        wakeupBox?.release()
        wakeupBox = nil
        continuation.finish()
    }

    // MARK: Commands

    public func load(_ url: URL, startAt: TimeInterval? = nil) {
        let target = url.isFileURL ? url.path : url.absoluteString
        facts.withLock { f in
            f.hasFile = true; f.fileLoaded = false; f.eof = false; f.failure = nil; f.lastErrorLog = nil
            f.snapshot.position = 0; f.snapshot.duration = nil; f.snapshot.bufferedAhead = nil
            f.lastEmittedPosition = -1
        }
        publishState()
        let args = (startAt ?? 0) > 0 ? ["loadfile", target, "replace", "-1", "start=\(startAt!)"] : ["loadfile", target, "replace"]
        if needsRenderContext, renderLock.withLock({ $0 == nil }) {
            pendingLoad.withLock { $0 = args }
            return
        }
        command(args)
        setProperty("pause", "no")
    }

    public func play() { setProperty("pause", "no") }
    public func pause() { setProperty("pause", "yes") }
    public func togglePause() { command(["cycle", "pause"]) }

    public func seek(to position: TimeInterval, exact: Bool) {
        command(["seek", String(max(0, position)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    public func seek(by delta: TimeInterval) { command(["seek", String(delta), "relative+exact"]) }

    public func selectAudioTrack(_ id: Int?) { setProperty("aid", id.map(String.init) ?? "no") }
    public func selectSubtitleTrack(_ id: Int?) { setProperty("sid", id.map(String.init) ?? "no") }

    public func setVolume(_ volume: Double) { setProperty("volume", String(min(1, max(0, volume)) * 100)) }
    public func setSpeed(_ speed: Double) { setProperty("speed", String(min(4, max(0.25, speed)))) }

    public func stop() {
        pendingLoad.withLock { $0 = nil }
        command(["stop"])
        facts.withLock { f in
            f.hasFile = false; f.fileLoaded = false; f.eof = false; f.failure = nil
            f.snapshot.position = 0; f.snapshot.duration = nil
        }
        publishState()
    }

    /// Runs `body` with the live handle while holding off `shutdown()`.
    private func command(_ args: [String]) {
        guard let h = handle else { return }
        var cstrings: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cstrings.append(nil)
        defer { for p in cstrings { Darwin.free(UnsafeMutablePointer(mutating: p)) } }
        _ = cstrings.withUnsafeMutableBufferPointer { api.commandAsync(h, 0, $0.baseAddress) }
    }

    /// Reads any libmpv property as a string (diagnostics, tests).
    func property(_ name: String) -> String? {
        guard !facts.withLock({ $0.closed }), let h = handle else { return nil }
        return api.string(h, property: name)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let h = handle else { return }
        _ = api.setPropertyString(h, name, value)
    }

    // MARK: Rendering hook

    /// Creates the libmpv render context for an OpenGL surface. The caller's GL context must be current.
    func makeRenderContext(getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?,
                           updateCallback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
                           updateContext: UnsafeMutableRawPointer?) throws -> MPVRenderContext {
        guard let h = handle else { throw EngineError.initializationFailed("engine is shut down") }
        let ctx = try MPVRenderContext(api: api, handle: h, getProcAddress: getProcAddress,
                                       updateCallback: updateCallback, updateContext: updateContext)
        renderLock.withLock { $0 = ctx }
        if let pending = pendingLoad.withLock({ p -> [String]? in defer { p = nil }; return p }) {
            command(pending)
            setProperty("pause", "no")
        }
        return ctx
    }

    func releaseRenderContext(_ ctx: MPVRenderContext) {
        renderLock.withLock { current in
            if current === ctx { current = nil }
        }
        ctx.free()
    }

    /// Takes a screenshot of the current frame (video only, no subtitles/OSD) to `url` (png/jpg by extension).
    public func screenshot(to url: URL) {
        command(["screenshot-to-file", url.path, "video"])
    }

    // MARK: Events

    private static let observed = ["pause", "core-idle", "paused-for-cache", "eof-reached", "time-pos", "duration",
                                   "demuxer-cache-time", "volume", "speed", "track-list", "aid", "sid", "seekable"]

    private static func format(of property: String) -> Int32 {
        switch property {
        case "pause", "core-idle", "paused-for-cache", "eof-reached", "seekable": Int32(MPV_FORMAT_FLAG.rawValue)
        case "time-pos", "duration", "demuxer-cache-time", "volume", "speed": Int32(MPV_FORMAT_DOUBLE.rawValue)
        default: Int32(MPV_FORMAT_STRING.rawValue)
        }
    }

    private func drainEvents() {
        guard !facts.withLock({ $0.closed }), let h = handle else { return }
        while true {
            guard let ev = api.waitEvent(h, 0) else { return }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            switch id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_START_FILE:
                facts.withLock { f in
                    f.hasFile = true; f.fileLoaded = false; f.eof = false; f.failure = nil
                }
                publishState()
            case MPV_EVENT_FILE_LOADED:
                facts.withLock { $0.fileLoaded = true }
                publishState()
            case MPV_EVENT_END_FILE:
                handleEndFile(ev.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee)
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = ev.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = msg.text {
                    let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                    facts.withLock { $0.lastErrorLog = line }
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                if let prop = ev.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                    handleProperty(prop)
                }
            default:
                break
            }
        }
    }

    private func handleEndFile(_ end: mpv_event_end_file?) {
        guard let end else { return }
        facts.withLock { f in
            switch end.reason {
            case MPV_END_FILE_REASON_ERROR:
                f.failure = Self.plainMessage(code: end.error, api: api, detail: f.lastErrorLog)
                f.hasFile = false
            case MPV_END_FILE_REASON_EOF:
                f.eof = true
            case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
                break  // a replacement START_FILE (or `stop()`) sets the next state
            default:
                break
            }
        }
        publishState()
    }

    private static func plainMessage(code: Int32, api: MPVLibrary, detail: String?) -> String {
        switch code {
        case Int32(MPV_ERROR_UNKNOWN_FORMAT.rawValue): return "This file's format isn't supported."
        case Int32(MPV_ERROR_LOADING_FAILED.rawValue): return "The file couldn't be opened. It may be incomplete or unreachable."
        case Int32(MPV_ERROR_AO_INIT_FAILED.rawValue): return "Audio output couldn't be started."
        case Int32(MPV_ERROR_VO_INIT_FAILED.rawValue): return "Video output couldn't be started."
        case Int32(MPV_ERROR_NOTHING_TO_PLAY.rawValue): return "There was nothing to play in this file."
        default: return detail ?? api.message(for: code)
        }
    }

    private enum PropertyValue {
        case none, flag(Bool), double(Double), string(String)
        var flag: Bool? { if case .flag(let v) = self { v } else { nil } }
        var double: Double? { if case .double(let v) = self { v } else { nil } }
        var string: String? { if case .string(let v) = self { v } else { nil } }
    }

    private func handleProperty(_ prop: mpv_event_property) {
        guard let cname = prop.name else { return }
        let name = String(cString: cname)
        let value: PropertyValue
        if let data = prop.data, prop.format != MPV_FORMAT_NONE {
            switch prop.format {
            case MPV_FORMAT_FLAG: value = .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
            case MPV_FORMAT_DOUBLE: value = .double(data.assumingMemoryBound(to: Double.self).pointee)
            case MPV_FORMAT_STRING:
                if let p = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee { value = .string(String(cString: p)) }
                else { value = .none }
            default: value = .none
            }
        } else {
            value = .none
        }

        let (emit, stateChanged): ([PlaybackEvent], Bool) = facts.withLock { f in
            var emit: [PlaybackEvent] = []
            var stateChanged = false
            switch name {
            case "pause": f.pause = value.flag ?? false; stateChanged = true
            case "core-idle": f.coreIdle = value.flag ?? true; stateChanged = true
            case "paused-for-cache": f.pausedForCache = value.flag ?? false; stateChanged = true
            case "eof-reached": f.eof = value.flag ?? false; stateChanged = true
            case "seekable":
                let v = value.flag ?? false
                if v != f.snapshot.isSeekable { f.snapshot.isSeekable = v; emit.append(.seekable(v)) }
            case "time-pos":
                let p = value.double ?? 0
                f.snapshot.position = p
                if abs(p - f.lastEmittedPosition) >= Self.positionQuantum || p < f.lastEmittedPosition {
                    f.lastEmittedPosition = p
                    emit.append(.position(p))
                }
            case "duration":
                f.snapshot.duration = value.double
                emit.append(.duration(value.double))
            case "demuxer-cache-time":
                if let t = value.double {
                    let ahead = max(0, t - f.snapshot.position)
                    let old = f.snapshot.bufferedAhead ?? -1
                    if abs(ahead - old) >= 0.5 { f.snapshot.bufferedAhead = ahead; emit.append(.bufferedAhead(ahead)) }
                } else if f.snapshot.bufferedAhead != nil {
                    f.snapshot.bufferedAhead = nil; emit.append(.bufferedAhead(nil))
                }
            case "volume":
                if let v = value.double { f.snapshot.volume = v / 100; emit.append(.volume(v / 100)) }
            case "speed":
                if let s = value.double { f.snapshot.speed = s; emit.append(.speed(s)) }
            case "track-list":
                let (audio, subs, selA, selS) = Self.parseTracks(value.string)
                f.snapshot.audioTracks = audio; f.snapshot.subtitleTracks = subs
                f.snapshot.selectedAudioTrack = selA; f.snapshot.selectedSubtitleTrack = selS
                emit.append(.tracks(audio: audio, subtitle: subs, selectedAudio: selA, selectedSubtitle: selS))
            case "aid", "sid":
                // Selection changed without the track list changing; refresh the selected ids.
                let id = value.string.flatMap { Int($0) }
                if name == "aid" { f.snapshot.selectedAudioTrack = id } else { f.snapshot.selectedSubtitleTrack = id }
                emit.append(.tracks(audio: f.snapshot.audioTracks, subtitle: f.snapshot.subtitleTracks,
                                    selectedAudio: f.snapshot.selectedAudioTrack, selectedSubtitle: f.snapshot.selectedSubtitleTrack))
            default: break
            }
            return (emit, stateChanged)
        }
        for e in emit { continuation.yield(e) }
        if stateChanged { publishState() }
    }

    private func publishState() {
        let newState: PlaybackState? = facts.withLock { f in
            let s = Self.derive(f)
            guard s != f.snapshot.state else { return nil }
            f.snapshot.state = s
            return s
        }
        if let newState { continuation.yield(.state(newState)) }
    }

    private static func derive(_ f: Facts) -> PlaybackState {
        if let failure = f.failure { return .failed(failure) }
        if !f.hasFile { return .idle }
        if f.eof { return .ended }
        if !f.fileLoaded { return .loading }
        if f.pausedForCache { return .buffering }
        if f.pause { return .paused }
        return f.coreIdle ? .buffering : .playing
    }

    private static func parseTracks(_ json: String?) -> (audio: [MediaTrack], subtitle: [MediaTrack], selectedAudio: Int?, selectedSubtitle: Int?) {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], [], nil, nil) }
        var audio: [MediaTrack] = [], subs: [MediaTrack] = []
        var selA: Int?, selS: Int?
        for t in list {
            guard let id = t["id"] as? Int, let type = t["type"] as? String else { continue }
            let kind: MediaTrack.Kind
            switch type {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue
            }
            let track = MediaTrack(
                id: id, kind: kind, title: t["title"] as? String, language: t["lang"] as? String,
                codec: t["codec"] as? String, channelCount: t["demux-channel-count"] as? Int,
                isDefault: t["default"] as? Bool ?? false, isForced: t["forced"] as? Bool ?? false,
                isExternal: t["external"] as? Bool ?? false)
            let selected = t["selected"] as? Bool ?? false
            if kind == .audio { audio.append(track); if selected { selA = id } }
            else { subs.append(track); if selected { selS = id } }
        }
        return (audio, subs, selA, selS)
    }
}
