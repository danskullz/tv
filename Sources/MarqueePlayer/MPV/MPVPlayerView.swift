import AppKit
import CMpv
import OpenGL.GL3
import os
import QuartzCore
import SwiftUI

/// Video surface for `MPVPlaybackEngine`, usable from SwiftUI.
///
/// Rendering uses libmpv's **OpenGL render API** inside a `CAOpenGLLayer` (macOS 15 still ships OpenGL
/// 4.1 on both Intel and Apple silicon). The layer is not asynchronous: libmpv's update callback is the
/// only thing that schedules a redraw, so a paused or idle player does zero GPU/CPU work.
///
/// A Metal/EDR path needs a libmpv render backend that targets Metal. mpv 0.41's render API only offers
/// OpenGL and software; its Metal-capable VO (`gpu-next` + `macvk`) runs through MoltenVK and owns its
/// own window/layer, so it cannot be embedded through the render API. Getting HDR/EDR output through
/// this API would mean either (a) tone-mapping to SDR inside libmpv (works today: `tone-mapping`,
/// `target-colorspace-hint=no`), or (b) a Metal render backend in mpv (upstream work) or a custom
/// libplacebo/Metal presenter fed by `hwdec=videotoolbox` IOSurfaces.
public struct MPVPlayerView: NSViewRepresentable {
    public let engine: MPVPlaybackEngine

    public init(engine: MPVPlaybackEngine) { self.engine = engine }

    public func makeNSView(context: Context) -> MPVVideoView { MPVVideoView(engine: engine) }
    public func updateNSView(_ nsView: MPVVideoView, context: Context) {}
    public static func dismantleNSView(_ nsView: MPVVideoView, coordinator: ()) { nsView.teardown() }
}

public final class MPVVideoView: NSView {
    private let engine: MPVPlaybackEngine

    public init(engine: MPVPlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func makeBackingLayer() -> CALayer {
        let layer = MPVVideoLayer(engine: engine)
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return layer
    }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Releases the render context while the GL context is still alive.
    public func teardown() { (layer as? MPVVideoLayer)?.teardown() }
}

/// `CAOpenGLLayer` that hands its framebuffer to libmpv.
final class MPVVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    private final class WeakBox: @unchecked Sendable {
        weak var layer: MPVVideoLayer?
    }

    private var engine: MPVPlaybackEngine?
    private var renderContext: MPVRenderContext?
    private var box: Unmanaged<WeakBox>?
    private let redrawPending = OSAllocatedUnfairLock(initialState: false)

    init(engine: MPVPlaybackEngine) {
        self.engine = engine
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        isOpaque = true
        let b = WeakBox()
        b.layer = self
        box = Unmanaged.passRetained(b)
    }

    /// Core Animation clones layers for its presentation tree; the clone only needs to draw nothing.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        teardown()
        box?.release()
    }

    func teardown() {
        if let ctx = renderContext, let engine { engine.releaseRenderContext(ctx) }
        renderContext = nil
        engine = nil
    }

    // MARK: Core Animation

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        func choose(profile: CGLOpenGLProfile) -> CGLPixelFormatObj? {
            let attrs: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(profile.rawValue)),
                kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
                kCGLPFAColorSize, CGLPixelFormatAttribute(24),
                kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
                kCGLPFADepthSize, CGLPixelFormatAttribute(0),
                CGLPixelFormatAttribute(0),
            ]
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            CGLChoosePixelFormat(attrs, &pixelFormat, &count)
            return pixelFormat
        }
        return choose(profile: kCGLOGLPVersion_GL4_Core) ?? choose(profile: kCGLOGLPVersion_3_2_Core)
            ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        var context: CGLContextObj?
        CGLCreateContext(pf, nil, &context)
        guard let context else { return super.copyCGLContext(forPixelFormat: pf) }
        var interval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &interval)
        return context
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        engine != nil
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        redrawPending.withLock { $0 = false }
        CGLSetCurrentContext(ctx)
        if renderContext == nil, let engine, let box {
            renderContext = try? engine.makeRenderContext(
                getProcAddress: { _, name in
                    guard let name else { return nil }
                    return CFBundleGetFunctionPointerForName(mpvGLBundle, String(cString: name) as CFString)
                },
                updateCallback: { raw in
                    guard let raw else { return }
                    Unmanaged<WeakBox>.fromOpaque(raw).takeUnretainedValue().layer?.scheduleRedraw()
                },
                updateContext: box.toOpaque())
        }

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        let width = GLint((bounds.width * contentsScale).rounded())
        let height = GLint((bounds.height * contentsScale).rounded())
        glViewport(0, 0, width, height)
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        if let renderContext {
            renderContext.render(fbo: fbo, width: width, height: height)
            glFlush()
            renderContext.reportSwap()
        }
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }

    /// Called from libmpv's thread: coalesce into one main-thread invalidation.
    private func scheduleRedraw() {
        let shouldSchedule = redrawPending.withLock { pending -> Bool in
            if pending { return false }
            pending = true
            return true
        }
        guard shouldSchedule else { return }
        let target = UncheckedSendable(self)
        DispatchQueue.main.async { target.value.setNeedsDisplay() }
    }
}

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

nonisolated(unsafe) private let mpvGLBundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
