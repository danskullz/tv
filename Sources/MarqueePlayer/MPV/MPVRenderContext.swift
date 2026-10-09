import CMpv
import Foundation
import OpenGL.GL3

/// Wraps `mpv_render_context` (OpenGL flavour). Created and used with the layer's CGL context current.
final class MPVRenderContext: @unchecked Sendable {
    private let api: MPVLibrary
    private var context: OpaquePointer?
    private let cglContext: CGLContextObj?
    private let lock = NSLock()

    init(api: MPVLibrary, handle: OpaquePointer,
         getProcAddress: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?,
         updateCallback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
         updateContext: UnsafeMutableRawPointer?) throws {
        self.api = api
        self.cglContext = CGLGetCurrentContext()

        var initParams = mpv_opengl_init_params(get_proc_address: getProcAddress, get_proc_address_ctx: nil)
        var created: OpaquePointer?
        let apiType = strdup("opengl")
        defer { Darwin.free(apiType) }
        let status: Int32 = withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return api.renderContextCreate(&created, handle, &params)
        }
        guard status >= 0, let created else {
            throw MPVPlaybackEngine.EngineError.initializationFailed("render context: \(api.message(for: status))")
        }
        context = created
        api.renderContextSetUpdateCallback(created, updateCallback, updateContext)
    }

    /// Draws the current frame into the currently bound framebuffer object.
    /// Returns false if there is nothing to draw yet.
    @discardableResult
    func render(fbo: Int32, width: Int32, height: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let context else { return false }
        _ = api.renderContextUpdate(context)
        var target = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        let status: Int32 = withUnsafeMutablePointer(to: &target) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return api.renderContextRender(context, &params)
            }
        }
        return status >= 0
    }

    func reportSwap() {
        lock.lock(); defer { lock.unlock() }
        if let context { api.renderContextReportSwap(context) }
    }

    /// Idempotent. Makes the owning GL context current for the duration, as libmpv requires.
    func free() {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = context else { return }
        context = nil
        let previous = CGLGetCurrentContext()
        if let cglContext { CGLSetCurrentContext(cglContext) }
        api.renderContextSetUpdateCallback(ctx, nil, nil)
        api.renderContextFree(ctx)
        CGLSetCurrentContext(previous)
    }

    deinit { free() }
}
