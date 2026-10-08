import SwiftUI
import Observation

/// Live state for one in-flight download. Views observe a single box, so a progress tick invalidates
/// only the card / row showing that download, not the whole grid.
@MainActor
@Observable
public final class ProgressBox {
    public internal(set) var fraction: Double
    public internal(set) var etaSeconds: TimeInterval?
    public internal(set) var bytesPerSecond: Double?

    init(fraction: Double, etaSeconds: TimeInterval? = nil, bytesPerSecond: Double? = nil) {
        self.fraction = fraction
        self.etaSeconds = etaSeconds
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Fans live progress from a `LibraryDataSource` out to per-id `ProgressBox`es.
///
/// The stream is consumed only while at least one view that shows progress is on screen
/// (`.followsLiveProgress()`) and the app is visible, so idle cost is zero.
@MainActor
@Observable
public final class DownloadTracker {
    @ObservationIgnored private var boxes: [String: ProgressBox] = [:]
    /// Bumped when a new box appears so views that looked up a missing box refresh once.
    private var boxGeneration = 0
    @ObservationIgnored private let source: any LibraryDataSource
    @ObservationIgnored private weak var lifecycle: AppLifecycle?
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(source: any LibraryDataSource, lifecycle: AppLifecycle? = nil) {
        self.source = source
        self.lifecycle = lifecycle
        lifecycle?.onVisibilityChange { [weak self] _ in self?.reconcile() }
    }

    /// The live box for `id`, if that id has ever reported progress.
    public func box(for id: String) -> ProgressBox? {
        _ = boxGeneration
        return boxes[id]
    }

    /// Creates boxes for ids that have initial values (call when loading screens).
    public func seed(_ updates: [ProgressUpdate]) { apply(updates) }

    public func acquire() {
        consumers += 1
        reconcile()
    }

    public func release() {
        consumers = max(0, consumers - 1)
        reconcile()
    }

    private func reconcile() {
        let shouldRun = consumers > 0 && (lifecycle?.isVisible ?? true)
        if shouldRun, task == nil {
            let stream = source.liveProgress()
            task = Task { [weak self] in
                for await batch in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(batch)
                }
            }
        } else if !shouldRun, let task {
            task.cancel()
            self.task = nil
        }
    }

    private func apply(_ updates: [ProgressUpdate]) {
        for u in updates {
            if let box = boxes[u.id] {
                box.fraction = u.fraction
                box.etaSeconds = u.etaSeconds
                box.bytesPerSecond = u.bytesPerSecond
            } else {
                boxes[u.id] = ProgressBox(fraction: u.fraction, etaSeconds: u.etaSeconds, bytesPerSecond: u.bytesPerSecond)
                boxGeneration += 1
            }
        }
    }
}

private struct LiveProgressModifier: ViewModifier {
    @Environment(DownloadTracker.self) private var tracker: DownloadTracker?

    func body(content: Content) -> some View {
        content
            .onAppear { tracker?.acquire() }
            .onDisappear { tracker?.release() }
    }
}

extension View {
    /// Keeps live download progress flowing while this view is on screen, and only then.
    public func followsLiveProgress() -> some View {
        modifier(LiveProgressModifier())
    }
}
