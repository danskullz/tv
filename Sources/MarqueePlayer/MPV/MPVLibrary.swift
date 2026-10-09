import CMpv
import Darwin
import Foundation

/// The libmpv entry points Marquee uses, resolved with `dlopen`/`dlsym` at runtime.
///
/// libmpv is LGPL and ships as a replaceable dylib in `Contents/Frameworks`; loading it dynamically
/// (rather than linking it) keeps the package building and testing on machines that have not run
/// `scripts/build-mpv.sh`, and lets a user drop in a modified libmpv without relinking the app.
public struct MPVLibrary: @unchecked Sendable {
    typealias Handle = OpaquePointer
    typealias WakeupCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let clientAPIVersion: @convention(c) () -> UInt
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let create: @convention(c) () -> Handle?
    let initialize: @convention(c) (Handle?) -> Int32
    let terminateDestroy: @convention(c) (Handle?) -> Void
    let setOptionString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let setPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let getPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    let commandAsync: @convention(c) (Handle?, UInt64, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let observeProperty: @convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
    let waitEvent: @convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?
    let setWakeupCallback: @convention(c) (Handle?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void
    let requestLogMessages: @convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32

    let renderContextCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextSetUpdateCallback: @convention(c) (OpaquePointer?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void
    let renderContextUpdate: @convention(c) (OpaquePointer?) -> UInt64
    let renderContextRender: @convention(c) (OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextReportSwap: @convention(c) (OpaquePointer?) -> Void
    let renderContextFree: @convention(c) (OpaquePointer?) -> Void

    /// File name of the library inside `Contents/Frameworks`.
    public static let libraryFileName = "libmpv.2.dylib"

    public enum LoadError: Error, CustomStringConvertible {
        case notFound([String])
        case dlopenFailed(String, String)
        case missingSymbol(String)
        public var description: String {
            switch self {
            case .notFound(let paths): "libmpv not found; looked in: \(paths.joined(separator: ", "))"
            case .dlopenFailed(let path, let msg): "could not load \(path): \(msg)"
            case .missingSymbol(let name): "libmpv is missing symbol \(name)"
            }
        }
    }

    /// Shared instance, or `nil` when libmpv cannot be found. Tests use this to skip when the vendored
    /// build is absent.
    public static let shared: MPVLibrary? = try? MPVLibrary.load()

    /// Candidate locations, most specific first: `$MARQUEE_LIBMPV` (file or directory), the app bundle's
    /// `Contents/Frameworks`, then `Vendor/mpv/lib` of this source checkout (development).
    public static func searchPaths(sourceFile: String = #filePath) -> [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["MARQUEE_LIBMPV"], !env.isEmpty {
            paths.append(env.hasSuffix(".dylib") ? env : (env as NSString).appendingPathComponent(libraryFileName))
        }
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append((frameworks as NSString).appendingPathComponent(libraryFileName))
        }
        if let exe = Bundle.main.executablePath {
            let dir = (exe as NSString).deletingLastPathComponent
            paths.append(((dir as NSString).appendingPathComponent("../Frameworks/") as NSString).appendingPathComponent(libraryFileName))
        }
        // …/Sources/MarqueePlayer/MPV/MPVLibrary.swift -> package root
        var root = URL(fileURLWithPath: sourceFile)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        paths.append(root.appendingPathComponent("Vendor/mpv/lib/\(libraryFileName)").path)
        return paths
    }

    public static func load(from explicitPath: String? = nil) throws -> MPVLibrary {
        let candidates = explicitPath.map { [$0] } ?? searchPaths()
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw LoadError.notFound(candidates)
        }
        guard let lib = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.dlopenFailed(path, String(cString: dlerror()))
        }
        func sym<T>(_ name: String, as _: T.Type) throws -> T {
            guard let p = dlsym(lib, name) else { throw LoadError.missingSymbol(name) }
            return unsafeBitCast(p, to: T.self)
        }
        return MPVLibrary(
            clientAPIVersion: try sym("mpv_client_api_version", as: (@convention(c) () -> UInt).self),
            errorString: try sym("mpv_error_string", as: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self),
            free: try sym("mpv_free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
            create: try sym("mpv_create", as: (@convention(c) () -> Handle?).self),
            initialize: try sym("mpv_initialize", as: (@convention(c) (Handle?) -> Int32).self),
            terminateDestroy: try sym("mpv_terminate_destroy", as: (@convention(c) (Handle?) -> Void).self),
            setOptionString: try sym("mpv_set_option_string", as: (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            setPropertyString: try sym("mpv_set_property_string", as: (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            getPropertyString: try sym("mpv_get_property_string", as: (@convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self),
            commandAsync: try sym("mpv_command_async", as: (@convention(c) (Handle?, UInt64, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
            observeProperty: try sym("mpv_observe_property", as: (@convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32).self),
            waitEvent: try sym("mpv_wait_event", as: (@convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?).self),
            setWakeupCallback: try sym("mpv_set_wakeup_callback", as: (@convention(c) (Handle?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void).self),
            requestLogMessages: try sym("mpv_request_log_messages", as: (@convention(c) (Handle?, UnsafePointer<CChar>?) -> Int32).self),
            renderContextCreate: try sym("mpv_render_context_create", as: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?) -> Int32).self),
            renderContextSetUpdateCallback: try sym("mpv_render_context_set_update_callback", as: (@convention(c) (OpaquePointer?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void).self),
            renderContextUpdate: try sym("mpv_render_context_update", as: (@convention(c) (OpaquePointer?) -> UInt64).self),
            renderContextRender: try sym("mpv_render_context_render", as: (@convention(c) (OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32).self),
            renderContextReportSwap: try sym("mpv_render_context_report_swap", as: (@convention(c) (OpaquePointer?) -> Void).self),
            renderContextFree: try sym("mpv_render_context_free", as: (@convention(c) (OpaquePointer?) -> Void).self)
        )
    }

    func message(for error: Int32) -> String {
        errorString(error).map { String(cString: $0) } ?? "mpv error \(error)"
    }

    /// Property value as a string (node properties come back as JSON). Caller need not free.
    func string(_ handle: Handle?, property name: String) -> String? {
        guard let raw = getPropertyString(handle, name) else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }
}
