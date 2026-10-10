import Foundation
import Synchronization
import os

/// Opt-in timing for the UI's hot paths. Silent (one static read) unless `MARQUEE_PERF=1` is in the
/// environment, so leaving calls in place costs nothing. Use it to prove a change actually helped
/// instead of arguing from theory:
///
///     MARQUEE_PERF=1 MARQUEE_TABS=2 ./Marquee 2>&1 | grep perf
public enum PerfLog {
    private static let enabled = ProcessInfo.processInfo.environment["MARQUEE_PERF"] == "1"
    private static let log = OSLog(subsystem: "com.marquee.app", category: "perf")

    /// True when `MARQUEE_PERF=1`.
    public static var isEnabled: Bool { enabled }

    /// Reads an integer environment variable, e.g. `MARQUEE_TABS` (number of sidebar passes).
    public static func envInt(_ name: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Spans

    /// Times `body` and prints its wall-clock duration with `label`. The closure is `sending` so an
    /// actor-isolated caller can measure its work without a data-race diagnostic.
    @discardableResult
    public static func measure<T>(_ label: String, _ body: sending () async throws -> T) async throws -> T {
        guard enabled else { return try await body() }
        let start = ContinuousClock.now
        defer { emit(label: label, elapsed: start.duration(to: .now)) }
        return try await body()
    }

    /// Records one already-measured duration.
    public static func record(_ label: String, seconds: Double) {
        guard enabled else { return }
        let millis = seconds * 1000
        os_signpost(.begin, log: log, name: "span", "label=%{public}s", label)
        os_signpost(.end, log: log, name: "span", "label=%{public}s ms=%{public}.3f", label, millis)
        emit(label: label, elapsed: .milliseconds(millis))
    }

    /// Marks a point in time, for spotting gaps between spans (e.g. time spent rendering).
    public static func mark(_ label: String) {
        guard enabled else { return }
        emit(label: label, elapsed: nil)
    }

    /// Seconds since `start`, for call sites that measure a stretch themselves.
    public static func seconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = start.duration(to: .now).components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    // MARK: - Stalls

    private struct Stalls { var count = 0; var worst = 0.0; var total = 0.0 }
    private static let stalls = Mutex(Stalls())
    private static let writeLock = NSLock()

    /// Prints the run's stall totals, so two runs can be compared like for like.
    public static func dumpStalls() {
        guard enabled else { return }
        let s = stalls.withLock { $0 }
        mark(String(format: "SUMMARY stalls=%d worst=%.1fms total=%.1fms", s.count, s.worst * 1000, s.total * 1000))
    }

    /// Zeroes the stall counters, so a measurement can exclude launch (which is a different problem)
    /// and cover only the interaction being tuned.
    public static func resetStalls() {
        stalls.withLock { $0 = Stalls() }
        mark("RESET")
    }

    fileprivate static func noteStall(_ seconds: Double) {
        stalls.withLock {
            $0.count += 1
            $0.worst = max($0.worst, seconds)
            $0.total += seconds
        }
    }

    // MARK: - Output

    private static func emit(label: String, elapsed: Duration?) {
        let text: String
        if let elapsed {
            let (seconds, attoseconds) = elapsed.components
            text = String(format: "perf %@ %.2fms", label, Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        } else {
            text = "perf \(label)"
        }
        writeLock.lock()
        FileHandle.standardError.write(Data((text + "\n").utf8))
        writeLock.unlock()
        os_signpost(.event, log: log, name: "mark", "label=%{public}s", label)
    }
}

/// Measures how long the main thread is unavailable, which is what "the UI feels laggy" actually
/// means. A repeating main-queue timer fires once per frame interval; any gap between when it was
/// due and when it actually ran is time the UI could not respond — a stall.
///
/// Started by the app only under `MARQUEE_PERF=1`; costs nothing otherwise.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private let interval: Double
    private let threshold: Double
    private let nextDue = Mutex<UInt64>(0)
    private let timerSlot = Mutex<DispatchSourceTimer?>(nil)

    public init(interval: Double = 1.0 / 60.0, threshold: Double = 0.016) {
        self.interval = interval
        self.threshold = threshold
    }

    public func start() {
        guard PerfLog.isEnabled else { return }
        guard timerSlot.withLock({ $0 == nil }) else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(0))
        let step = UInt64(interval * 1e9)
        nextDue.withLock { $0 = DispatchTime.now().uptimeNanoseconds + step }
        source.setEventHandler { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            let lateness = nextDue.withLock { due -> Double in
                // Negative means it fired early (the first one can); only lateness is interesting.
                let late = max(0, Double(Int64(bitPattern: now &- due)) / 1e9)
                // Starved for more than a frame: re-sync instead of accumulating debt, or the
                // reported lateness grows without bound.
                due = late > interval ? now + step : due + step
                return late
            }
            guard lateness >= threshold else { return }
            PerfLog.noteStall(lateness)
            PerfLog.mark(String(format: "stall %.1fms", lateness * 1000))
        }
        source.resume()
        timerSlot.withLock { $0 = source }
    }

    public func stop() {
        timerSlot.withLock { $0 }?.cancel()
        timerSlot.withLock { $0 = nil }
    }
}