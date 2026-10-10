import AppKit
import MarqueeCore
import Observation

/// Tracks whether the app is visible / active so idle work stops and decoded images are released
/// when the app is backgrounded (SCOPE §5.6: "UI releases image/decoded caches when backgrounded").
@MainActor
@Observable
public final class AppLifecycle {
    /// At least one window is on screen and not occluded.
    public private(set) var isVisible = true
    /// False once the app has been in the background long enough that decoded images were dropped.
    /// Image views clear their pixels while this is false and reload from the disk cache on return.
    public private(set) var imagesResident = true

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var visibilityHandlers: [@MainActor (Bool) -> Void] = []

    /// Seconds spent in the background before decoded images are released.
    public static let purgeDelay: Duration = .seconds(15)

    public init() {}

    /// Begins observing application notifications. Call once after launch.
    public func start() {
        MainThreadWatchdog.shared.start()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor (AppLifecycle) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            }
            observers.append(token)
        }
        add(NSApplication.didResignActiveNotification) { $0.scheduleImagePurge() }
        add(NSApplication.didHideNotification) { $0.purgeImagesNow() }
        add(NSApplication.didBecomeActiveNotification) { $0.cancelPurgeAndRestore() }
        add(NSApplication.didUnhideNotification) { $0.cancelPurgeAndRestore() }
        add(NSApplication.didChangeOcclusionStateNotification) { me in
            me.setVisible(NSApplication.shared.occlusionState.contains(.visible))
        }
        // The system asks apps to shed memory under pressure.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.purgeCachesOnly() }
        }
        source.resume()
        pressureSource = source
    }

    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?

    /// Registers a callback for visibility changes (used by `DownloadTracker` to pause live updates).
    public func onVisibilityChange(_ handler: @escaping @MainActor (Bool) -> Void) {
        visibilityHandlers.append(handler)
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visibilityHandlers.forEach { $0(visible) }
    }

    private func scheduleImagePurge() {
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.purgeDelay)
            guard !Task.isCancelled else { return }
            self?.purgeImagesNow()
        }
    }

    private func cancelPurgeAndRestore() {
        purgeTask?.cancel()
        purgeTask = nil
        imagesResident = true
    }

    private func purgeImagesNow() {
        purgeTask?.cancel()
        purgeTask = nil
        imagesResident = false
        purgeCachesOnly()
    }

    private func purgeCachesOnly() {
        ImagePipeline.shared.purgeMemory()
    }
}
