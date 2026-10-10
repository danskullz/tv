import CoreGraphics
import Foundation

// Prints the CGWindowID of the first on-screen window owned by `argv[1]`.
// `screencapture -l` needs a CGWindowID, which System Events does not expose.

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Marquee"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == wanted else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? Double) ?? 0
    let height = (bounds["Height"] as? Double) ?? 0
    // Skip tooltips and other tiny helper windows.
    if width > 200, height > 200 {
        print(window[kCGWindowNumber as String] as? Int ?? 0)
        exit(0)
    }
}
exit(1)