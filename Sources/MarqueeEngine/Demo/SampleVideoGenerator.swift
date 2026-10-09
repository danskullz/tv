import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Generates a synthetic H.264 test-pattern clip at run time, so the demo swarm needs no media files
/// and no content from anywhere. The picture shows what it is (series, episode, a running timecode,
/// colour bars and a sweeping bar) so a screenshot proves the right file is playing and playing smoothly.
public enum SampleVideoGenerator {
    public struct Spec: Sendable {
        public var title: String
        public var subtitle: String
        public var duration: Double
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        /// 0...1, tints the background so each episode looks different.
        public var hue: Double
        public var bitsPerSecond: Int

        public init(
            title: String, subtitle: String, duration: Double = 20, width: Int = 1280, height: Int = 720,
            framesPerSecond: Int = 24, hue: Double = 0.6, bitsPerSecond: Int = 2_500_000
        ) {
            self.title = title
            self.subtitle = subtitle
            self.duration = duration
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.hue = hue
            self.bitsPerSecond = bitsPerSecond
        }
    }

    public enum GeneratorError: Error, Sendable {
        case writerFailed(String)
    }

    /// Writes an MP4 (index at the head, like a web release) to `url`, replacing any existing file.
    /// Blocking: call from a background task.
    public static func generate(_ spec: Spec, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.bitsPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: spec.framesPerSecond * 2,
                AVVideoExpectedSourceFrameRateKey: spec.framesPerSecond,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
            ])
        guard writer.canAdd(input) else { throw GeneratorError.writerFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw GeneratorError.writerFailed(writer.error?.localizedDescription ?? "cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(spec.duration * Double(spec.framesPerSecond))
        for frame in 0..<frameCount {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                usleep(1000)
                waited += 1
                // Some machines (CI virtual machines) have no video encoder: the input never becomes ready.
                if waited > 8000 { throw GeneratorError.writerFailed("no video encoder available") }
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            draw(frame: frame, of: frameCount, spec: spec, into: buffer)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.framesPerSecond))
            if !adaptor.append(buffer, withPresentationTime: time) { break }
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        if done.wait(timeout: .now() + 60) == .timedOut { throw GeneratorError.writerFailed("finishing timed out") }
        guard writer.status == .completed else {
            throw GeneratorError.writerFailed(writer.error?.localizedDescription ?? "writer did not complete")
        }
    }

    // MARK: Drawing

    private static func draw(frame: Int, of total: Int, spec: Spec, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = spec.width, height = spec.height
        guard let base = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        let w = CGFloat(width), h = CGFloat(height)
        let progress = Double(frame) / Double(max(1, total - 1))
        let seconds = Double(frame) / Double(spec.framesPerSecond)

        // Background: a slow vertical gradient in the episode's hue.
        let top = CGColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)
        let bottom = Self.color(hue: spec.hue, saturation: 0.55, brightness: 0.45 + 0.1 * sin(seconds))
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Colour bars along the top.
        let bars: [CGColor] = [
            CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0.75, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0.75, blue: 0.75, alpha: 1), CGColor(red: 0, green: 0.75, blue: 0, alpha: 1),
            CGColor(red: 0.75, green: 0, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 0.75, alpha: 1),
        ]
        let barWidth = w / CGFloat(bars.count)
        for (i, color) in bars.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(i) * barWidth, y: h * 0.78, width: barWidth + 1, height: h * 0.22))
        }

        // Sweeping bar: proves smooth motion and shows seeks.
        let sweepX = CGFloat(progress) * (w - 24)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fill(CGRect(x: sweepX, y: 0, width: 24, height: h * 0.78))

        // A bouncing square for per-frame motion.
        let bounce = abs(sin(seconds * 2.2))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: w * 0.12, y: h * 0.1 + CGFloat(bounce) * h * 0.4, width: 56, height: 56))

        // Text.
        drawText(spec.title.uppercased(), size: h * 0.075, at: CGPoint(x: w * 0.5, y: h * 0.56), in: context, width: w)
        drawText(spec.subtitle, size: h * 0.05, at: CGPoint(x: w * 0.5, y: h * 0.46), in: context, width: w)
        let minutes = Int(seconds) / 60
        let timecode = String(format: "%02d:%04.1f", minutes, seconds - Double(minutes * 60))
        drawText(timecode, size: h * 0.12, at: CGPoint(x: w * 0.5, y: h * 0.28), in: context, width: w, monospaced: true)
        drawText(
            "frame \(frame)", size: h * 0.035, at: CGPoint(x: w * 0.5, y: h * 0.16), in: context, width: w, alpha: 0.7)
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let c = brightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(hue * 6) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }

    private static func drawText(
        _ text: String, size: CGFloat, at center: CGPoint, in context: CGContext, width: CGFloat,
        monospaced: Bool = false, alpha: CGFloat = 1
    ) {
        let font = CTFontCreateWithName((monospaced ? "Menlo-Bold" : "Helvetica-Bold") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.saveGState()
        // Soft shadow keeps text legible over the bars.
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
        context.textPosition = CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
