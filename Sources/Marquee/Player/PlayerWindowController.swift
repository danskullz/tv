import AppKit
import MarqueeUI
import SwiftUI

/// Borderless-feeling window: transparent titlebar over full-size content, black, full-screen capable.
/// Keys are intercepted in `sendEvent` so a focused button can never swallow Space or the arrows.
final class PlayerWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    var activityHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                // Esc: leave full screen first, then close.
                if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { performClose(nil) }
                return
            }
            if keyHandler?(event) == true { return }
        case .mouseMoved, .leftMouseDragged:
            activityHandler?()
        default:
            break
        }
        super.sendEvent(event)
    }

    // Esc and ⌘. arrive here when nothing else handles them.
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { performClose(nil) }
    }
}

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    let window: PlayerWindow
    private(set) var session: PlayerSession
    private let host: NSHostingView<AnyView>
    var onWindowClosed: (() -> Void)?
    private var suppressCloseCallback = false
    private var menuObservers: [any NSObjectProtocol] = []

    init(session: PlayerSession) {
        self.session = session
        host = NSHostingView(rootView: AnyView(PlayerRootView(session: session)))
        host.sizingOptions = []
        window = PlayerWindow(
            contentRect: Self.defaultFrame(), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        window.contentView = host
        window.title = session.request.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)  // video chrome is always dark
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 560, height: 315)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MarqueePlayerWindow")
        install(session: session)

        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.menuTrackingChanged(true) }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.menuTrackingChanged(false) }
            },
        ]
    }

    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(visible.width * 0.62, 800), 1480)
        let size = NSSize(width: width, height: (width * 9 / 16).rounded())
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func install(session: PlayerSession) {
        self.session = session
        session.toggleFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        session.requestClose = { [weak self] in self?.window.performClose(nil) }
        session.controlsVisibilityChanged = { [weak self] visible in self?.setTrafficLights(visible: visible) }
        session.isFullScreen = window.styleMask.contains(.fullScreen)
        window.keyHandler = { [weak session] event in session?.handleKey(event) ?? false }
        window.activityHandler = { [weak session] in session?.userActivity() }
        window.title = session.request.title
        setTrafficLights(visible: true, animated: false)
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Swaps playback in place (Up Next), keeping the window and its full-screen state.
    func replace(session newSession: PlayerSession) {
        let old = session
        host.rootView = AnyView(PlayerRootView(session: newSession))
        install(session: newSession)
        old.shutdown(notifyClose: false)
    }

    func close(notify: Bool) {
        suppressCloseCallback = !notify
        window.close()
    }

    // MARK: Chrome

    private func setTrafficLights(visible: Bool, animated: Bool = true) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            if animated && !reduce {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    button.animator().alphaValue = visible ? 1 : 0
                }
            } else {
                button.alphaValue = visible ? 1 : 0
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for o in menuObservers { NotificationCenter.default.removeObserver(o) }
        menuObservers = []
        session.shutdown(notifyClose: !suppressCloseCallback)
        host.rootView = AnyView(EmptyView())
        onWindowClosed?()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { session.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { session.isFullScreen = false }

    func windowDidBecomeKey(_ notification: Notification) { session.userActivity() }
}
