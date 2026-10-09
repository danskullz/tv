import Foundation

/// What the importer decides about a file from its name and first bytes, before it touches it.
/// Downloaded files are never executed and never opened by anything but the media probe.
public enum FileVerdict: Sendable, Hashable {
    /// A video container the importer handles.
    case media
    /// Sidecar subtitles (kept with the torrent for now).
    case subtitle
    /// An archive that needs extracting first (the importer leaves it where it is).
    case archive
    /// Not media (NFO, artwork, text): ignored.
    case ignored
    /// Executable, installer, script or disguised binary: refused with a health issue.
    case suspicious(reason: String)
}

public enum FileSafety {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "ts", "m2ts", "mts", "webm", "mpg", "mpeg", "flv", "ogm",
        "ogv", "divx", "vob", "3gp", "asf", "rmvb",
    ]
    public static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]
    public static let archiveExtensions: Set<String> = ["rar", "zip", "7z", "tar", "gz", "bz2", "xz", "iso", "img"]
    /// Things that run, install or script. Refused whatever the file name claims elsewhere.
    public static let dangerousExtensions: Set<String> = [
        "exe", "scr", "com", "bat", "cmd", "msi", "pif", "lnk", "vbs", "vbe", "js", "jse", "wsf", "ps1", "jar",
        "app", "command", "sh", "zsh", "bash", "pkg", "dmg", "action", "workflow", "scpt", "applescript",
        "dylib", "so", "dll", "apk", "ipa", "py", "pl", "rb", "terminal", "url", "webloc", "hta", "reg",
    ]

    /// Classifies by name alone.
    public static func classify(fileName: String) -> FileVerdict {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if dangerousExtensions.contains(ext) { return .suspicious(reason: "Executable or script file (.\(ext))") }
        if videoExtensions.contains(ext) { return .media }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if archiveExtensions.contains(ext) || isNumberedArchivePart(ext) { return .archive }
        return .ignored
    }

    /// Classifies by name, then reads the first bytes: a program dressed up with a video extension is
    /// suspicious however it is named.
    public static func inspect(_ url: URL) -> FileVerdict {
        let byName = classify(fileName: url.lastPathComponent)
        guard byName == .media else { return byName }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return byName }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count >= 2 else { return byName }
        let bytes = [UInt8](head)
        if let reason = executableSignature(bytes) { return .suspicious(reason: "\(reason) disguised as a video") }
        return .media
    }

    private static func isNumberedArchivePart(_ ext: String) -> Bool {
        // .r00 .r01 ... and .001 .002 ...
        if ext.count == 3, ext.first == "r", ext.dropFirst().allSatisfy(\.isNumber) { return true }
        return ext.count == 3 && ext.allSatisfy(\.isNumber)
    }

    private static func executableSignature(_ b: [UInt8]) -> String? {
        if b.count >= 2, b[0] == 0x4D, b[1] == 0x5A { return "Windows program" }
        if b.count >= 2, b[0] == 0x23, b[1] == 0x21 { return "Script" }
        if b.count >= 4 {
            let magic = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            // Mach-O (thin and fat), either endianness.
            if [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA].contains(magic) {
                return "macOS program"
            }
            if b[0] == 0x7F, b[1] == 0x45, b[2] == 0x4C, b[3] == 0x46 { return "Linux program" }
        }
        return nil
    }
}
