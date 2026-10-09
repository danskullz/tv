import AppKit
import SwiftUI

/// Transparent layer over the video that turns clicks into player gestures: click = play/pause,
/// double-click = full screen, drag = move the window. Single click waits out the double-click interval
/// (one-shot work item, no polling) so a double-click never flashes pause.
struct PlayerInputLayer: NSViewRepresentable {
    var onClick: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> InputView {
        let v = InputView()
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: InputView, context: Context) {
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class InputView: NSView {
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        private var pending: DispatchWorkItem?
        private var dragged = false

        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { dragged = false }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let window, !window.styleMask.contains(.fullScreen) else { return }
            dragged = true
            pending?.cancel()
            window.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard !dragged else { return }
            if event.clickCount >= 2 {
                pending?.cancel()
                onDoubleClick()
            } else {
                let work = DispatchWorkItem { [weak self] in self?.onClick() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
    }
}
