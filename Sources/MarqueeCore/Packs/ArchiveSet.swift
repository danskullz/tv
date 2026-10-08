import Foundation

public enum ArchiveFormat: String, Sendable, Hashable, Codable {
    case rar, zip, sevenZip
    /// Raw split files (`name.001`) or archives that are never multi-volume (`.tar`, `.gz`).
    case other
}

public struct ArchiveVolume: Sendable, Hashable {
    public var fileIndex: Int
    public var path: String
    public var size: Int64
    /// Offset in the torrent payload.
    public var offset: Int64
    /// Raw number from the file name (`part03` is 3, `.r00` is 1 after `.rar` as 0, `.z01` is 1).
    public var number: Int
}

/// The ordered volumes of one logical archive. Parsing the archive itself is out of scope here; this
/// only gets the grouping and ordering right so a later component can stream stored archives.
public struct ArchiveSet: Sendable, Hashable, Identifiable {
    /// Stable id: lower-cased `directory/baseName` plus format.
    public var id: String
    public var format: ArchiveFormat
    public var baseName: String
    public var directory: String
    /// Volumes in the order the archive must be read.
    public var volumes: [ArchiveVolume]
    /// Volume numbers (in the numbering of ``ArchiveVolume/number``) that are absent from the pack.
    public var missingVolumes: [Int]
    /// Episodes the set contains; empty when the set covers the whole pack or could not be tied to an episode.
    public var episodes: [EpisodeRef]

    public var isComplete: Bool { missingVolumes.isEmpty }
    public var totalSize: Int64 { volumes.reduce(0) { $0 + $1.size } }
    public var fileIndexes: [Int] { volumes.map(\.fileIndex) }
}

public enum ArchiveGrouper {
    struct Classified {
        var format: ArchiveFormat
        var base: String
        var number: Int
        /// zip: the final `.zip` file, ordered after every `.zNN`.
        var isZipTail = false
        /// First number expected in a complete set.
        var firstNumber: Int
    }

    /// True when the file name looks like (a volume of) an archive.
    public static func isArchiveName(_ path: String) -> Bool { classify(fileName(path)) != nil }

    /// Groups archive files into ordered sets. Sets are returned ordered by first volume file index.
    public static func group(_ files: [PackFile]) -> [ArchiveSet] {
        struct Bucket {
            var format: ArchiveFormat
            var base: String
            var dir: String
            var items: [(Classified, PackFile)] = []
        }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        for f in files {
            let (dir, name) = split(f.path)
            guard let c = classify(name) else { continue }
            let key = "\(dir.lowercased())/\(c.base.lowercased())|\(c.format.rawValue)"
            if buckets[key] == nil {
                buckets[key] = Bucket(format: c.format, base: c.base, dir: dir)
                order.append(key)
            }
            buckets[key]!.items.append((c, f))
        }
        var sets: [ArchiveSet] = []
        for key in order {
            guard var b = buckets[key] else { continue }
            let maxZ = b.items.filter { !$0.0.isZipTail }.map(\.0.number).max() ?? 0
            for i in b.items.indices where b.items[i].0.isZipTail { b.items[i].0.number = maxZ + 1 }
            b.items.sort { ($0.0.number, $0.1.index) < ($1.0.number, $1.1.index) }
            let volumes = b.items.map { c, f in
                ArchiveVolume(fileIndex: f.index, path: f.path, size: f.size, offset: f.offset, number: c.number)
            }
            // Missing = gaps between the expected first number and the highest present.
            let present = Set(volumes.map(\.number))
            var missing: [Int] = []
            let first = b.items.first!.0.firstNumber
            let last = volumes.last!.number
            if last >= first { for n in first...last where !present.contains(n) { missing.append(n) } }
            if b.format == .zip, !b.items.contains(where: { $0.0.isZipTail }), b.items.contains(where: { $0.0.number >= 1 }) {
                missing.append(last + 1)  // z01.. present but the closing .zip is not
            }
            sets.append(ArchiveSet(
                id: key, format: b.format, baseName: b.base, directory: b.dir, volumes: volumes,
                missingVolumes: missing, episodes: []))
        }
        return sets.sorted { $0.volumes[0].fileIndex < $1.volumes[0].fileIndex }
    }

    // MARK: Classification

    static func fileName(_ path: String) -> String {
        split(path).1
    }

    static func split(_ path: String) -> (String, String) {
        let comps = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard let last = comps.last else { return ("", path) }
        return (comps.dropLast().joined(separator: "/"), String(last))
    }

    static func classify(_ name: String) -> Classified? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        let stem = String(name[..<dot])

        func trailingNumber(_ s: String) -> Int? { s.isEmpty || s.contains(where: { !$0.isASCII || !$0.isNumber }) ? nil : Int(s) }

        switch ext {
        case "rar":
            if let (base, n) = partSuffix(stem) {
                return Classified(format: .rar, base: base, number: n, firstNumber: 1)
            }
            return Classified(format: .rar, base: stem, number: 0, firstNumber: 0)
        case "zip":
            return Classified(format: .zip, base: stem, number: 0, isZipTail: true, firstNumber: 1)
        case "7z":
            return Classified(format: .sevenZip, base: stem, number: 1, firstNumber: 1)
        case "tar", "gz", "tgz":
            return Classified(format: .other, base: name, number: 1, firstNumber: 1)
        default:
            break
        }
        let chars = Array(ext)
        // .r00 / .s01 ... after a .rar first volume
        if chars.count == 3, let l = chars.first, ("r"..."y").contains(l),
           let nn = Int(String(chars[1...])), chars[1...].allSatisfy(\.isNumber) {
            let idx = Int(l.asciiValue! - Character("r").asciiValue!)
            return Classified(format: .rar, base: stem, number: 1 + idx * 100 + nn, firstNumber: 0)
        }
        // .z01 ... zip volumes
        if chars.count == 3, chars[0] == "z", let nn = Int(String(chars[1...])), chars[1...].allSatisfy(\.isNumber) {
            return Classified(format: .zip, base: stem, number: nn, firstNumber: 1)
        }
        // .001 numeric splits, optionally behind .7z/.zip/.rar
        if let n = trailingNumber(ext), ext.count >= 3 {
            let inner = stem.lowercased()
            if inner.hasSuffix(".7z") {
                return Classified(format: .sevenZip, base: String(stem.dropLast(3)), number: n, firstNumber: 1)
            }
            if inner.hasSuffix(".zip") {
                return Classified(format: .zip, base: String(stem.dropLast(4)), number: n, isZipTail: false, firstNumber: 1)
            }
            if inner.hasSuffix(".rar") {
                if let (base, _) = partSuffix(String(stem.dropLast(4))) {
                    return Classified(format: .rar, base: base, number: n, firstNumber: 1)
                }
                return Classified(format: .rar, base: String(stem.dropLast(4)), number: n, firstNumber: 1)
            }
            return Classified(format: .other, base: stem, number: n, firstNumber: 1)
        }
        return nil
    }

    /// `name.part03` -> (`name`, 3).
    private static func partSuffix(_ stem: String) -> (String, Int)? {
        guard let dot = stem.lastIndex(where: { $0 == "." || $0 == " " || $0 == "_" || $0 == "-" }) else { return nil }
        let tail = stem[stem.index(after: dot)...].lowercased()
        guard tail.hasPrefix("part"), tail.count > 4, let n = Int(tail.dropFirst(4)) else { return nil }
        return (String(stem[..<dot]), n)
    }
}
