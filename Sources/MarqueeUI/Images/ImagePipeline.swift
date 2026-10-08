import Foundation
import ImageIO
import CryptoKit
import CoreGraphics

/// Loads remote artwork with a memory tier (`NSCache`, cost-limited), a disk tier (original bytes in
/// the Caches directory), request de-duplication, and ImageIO downsampling to the size actually
/// displayed. Decoding at display size is what keeps 5k-poster grids inside the 120 fps budget:
/// a 2000 px poster costs ~16 MB decoded, a 160 pt card at 2x costs ~0.2 MB.
public final class ImagePipeline: @unchecked Sendable {
    public static let shared = ImagePipeline()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memory = NSCache<NSString, Box>()
    private let session: URLSession
    private let directory: URL
    private let lock = NSLock()
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private var didTrimDisk = false

    /// Decoded images are cached in 64 px size buckets so slider drags don't create one entry per pixel.
    private static let bucket = 64
    /// Disk cache ceiling, trimmed (oldest first) the first time the pipeline is used in a process.
    private static let diskLimit = 300 * 1024 * 1024

    public init(session: URLSession? = nil, directory: URL? = nil, memoryLimitBytes: Int = 96 * 1024 * 1024) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.urlCache = nil   // we own the disk tier
            config.httpMaximumConnectionsPerHost = 6
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Marquee", isDirectory: true)
                .appendingPathComponent("Artwork", isDirectory: true)
        memory.totalCostLimit = memoryLimitBytes
        memory.countLimit = 4000
    }

    // MARK: Public

    /// A decoded image for `url` no larger than `pixelSize` (in pixels), or nil if unavailable.
    public func image(for url: URL, pixelSize: CGSize) async -> CGImage? {
        let maxPixel = Self.bucketed(max(pixelSize.width, pixelSize.height))
        let key = "\(url.absoluteString)#\(maxPixel)"
        if let hit = memory.object(forKey: key as NSString) { return hit.image }

        let task: Task<CGImage?, Never> = lock.withLock {
            if let existing = inflight[key] { return existing }
            let created = Task.detached(priority: .userInitiated) { [self] in
                let image = await load(url: url, maxPixel: maxPixel)
                if let image {
                    memory.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
                }
                lock.withLock { _ = inflight.removeValue(forKey: key) }
                return image
            }
            inflight[key] = created
            return created
        }
        return await task.value
    }

    /// Synchronous memory-only lookup, safe to call from `body`.
    public func cachedImage(for url: URL, pixelSize: CGSize) -> CGImage? {
        let maxPixel = Self.bucketed(max(pixelSize.width, pixelSize.height))
        return memory.object(forKey: "\(url.absoluteString)#\(maxPixel)" as NSString)?.image
    }

    /// Drops every decoded image (called when the app backgrounds or the system is under memory pressure).
    public func purgeMemory() {
        memory.removeAllObjects()
    }

    /// Removes the on-disk cache.
    public func purgeDisk() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Loading

    private func load(url: URL, maxPixel: Int) async -> CGImage? {
        trimDiskIfNeeded()
        let file = diskFile(for: url)
        if let image = Self.downsample(url: file, maxPixel: maxPixel) { return image }
        guard let data = await fetch(url) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return Self.downsample(data: data, maxPixel: maxPixel)
    }

    private func fetch(_ url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    private func diskFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    private func trimDiskIfNeeded() {
        let shouldTrim = lock.withLock { () -> Bool in
            defer { didTrimDisk = true }
            return !didTrimDisk
        }
        guard shouldTrim else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > Self.diskLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > Self.diskLimit * 3 / 4 {
            try? fm.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    // MARK: Downsampling

    static func bucketed(_ value: CGFloat) -> Int {
        max(bucket, Int((value / CGFloat(bucket)).rounded(.up)) * bucket)
    }

    private static func thumbnailOptions(maxPixel: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode now, off the main thread
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
    }

    static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions(maxPixel: maxPixel))
    }

    static func downsample(data: Data, maxPixel: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions(maxPixel: maxPixel))
    }
}
