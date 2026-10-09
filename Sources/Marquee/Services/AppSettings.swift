import Foundation
import MarqueeCore

/// User preferences that the services read at the moment they need them (so a change in Settings
/// applies to the next Play without restarting anything).
enum AppSettings {
    private static let downloadFolderKey = "downloadFolder"
    private static let presetKey = "defaultQualityPreset"

    /// Where torrents are written. Default `~/Movies/Marquee`.
    static var downloadFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: downloadFolderKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultDownloadFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: downloadFolderKey) }
    }

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Marquee", isDirectory: true)
    }

    static var isDefaultDownloadFolder: Bool {
        (UserDefaults.standard.string(forKey: downloadFolderKey) ?? "").isEmpty
    }

    static func resetDownloadFolder() { UserDefaults.standard.removeObject(forKey: downloadFolderKey) }

    /// The preset new titles start with.
    static var defaultPreset: QualityProfileConfig {
        get {
            let name = UserDefaults.standard.string(forKey: presetKey)
            return QualityProfileConfig.presets.first { $0.name == name } ?? .balanced
        }
        set { UserDefaults.standard.set(newValue.name, forKey: presetKey) }
    }

    /// Free bytes on the volume holding the download folder (nearest existing parent).
    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// One-line, plain-language blurbs for the preset picker.
extension QualityProfileConfig {
    var presetBlurb: String {
        switch name {
        case "Efficient": "720p to 1080p, small files. Best for slower connections."
        case "Balanced": "720p to 1080p from web and disc sources. The sensible default."
        case "Best": "2160p HDR with lossless audio when it exists, 1080p otherwise."
        case "Anime": "Fansub and BD releases, dual audio preferred."
        case "Remux": "Untouched disc remuxes only. Very large files."
        default: ""
        }
    }
}
