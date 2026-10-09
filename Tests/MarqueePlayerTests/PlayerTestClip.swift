import AVFoundation
import VideoToolbox
import CoreText
import Foundation

/// Generates a short H.264 + AAC test clip with Apple frameworks only (no downloaded media, no ffmpeg).
/// 3 s, 640x360 @ 30 fps: moving colour bars, a sweeping white marker and a frame counter, plus a quiet 440 Hz tone.
enum PlayerTestClip {
    static let duration: Double = 3
    static let fps: Int32 = 30
    static let size = CGSize(width: 640, height: 360)
    static let sampleRate = 44_100.0

    private static let cache = PlayerTestClipCache()

    /// Stable path so the app's `--play` hook can reuse the clip the tests produced.
    static var defaultURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("marquee-player-test-clip.mp4")
    }

    static func url() async throws -> URL { try await cache.url() }

    static func generate(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000, AVVideoMaxKeyFrameIntervalKey: 15],
            // Software encoder: CI VMs have no hardware video encoder, and the input never becomes ready there.
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate, AVEncoderBitRateKey: 64_000,
        ])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Never hang: a failed writer leaves inputs not-ready forever, so check status and a deadline.
        let deadline = ContinuousClock.now + .seconds(30)
        func checkProgress() throws {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            if ContinuousClock.now > deadline { throw PlayerTestClipError.timedOut }
        }

        // AVAssetWriter interleaves tracks: feed audio alongside video or both inputs stall.
        let frameCount = Int(duration * Double(fps))
        let chunk = 1024
        let totalAudio = Int(duration * sampleRate)
        var audioWritten = 0
        func feedAudio(upTo target: Int, blocking: Bool) async throws {
            while audioWritten < min(target, totalAudio) {
                if !audio.isReadyForMoreMediaData {
                    if !blocking { return }
                    try checkProgress()
                    try await Task.sleep(for: .milliseconds(2)); continue
                }
                let count = min(chunk, totalAudio - audioWritten)
                audio.append(try makeAudio(startFrame: audioWritten, count: count))
                audioWritten += count
            }
        }
        for n in 0..<frameCount {
            while !video.isReadyForMoreMediaData {
                try await feedAudio(upTo: Int((Double(n) / Double(fps) + 0.5) * sampleRate), blocking: false)
                try checkProgress()
                try await Task.sleep(for: .milliseconds(2))
            }
            adaptor.append(try makeFrame(index: n, of: frameCount), withPresentationTime: CMTime(value: CMTimeValue(n), timescale: fps))
            try await feedAudio(upTo: Int((Double(n) / Double(fps) + 0.5) * sampleRate), blocking: false)
        }
        video.markAsFinished()
        try await feedAudio(upTo: totalAudio, blocking: true)
        audio.markAsFinished()

        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func makeFrame(index: Int, of count: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }

        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1)]
        let barWidth = size.width / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0 * 0.75, green: c.1 * 0.75, blue: c.2 * 0.75, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: size.height * 0.3, width: barWidth, height: size.height * 0.7))
        }
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.3))
        // Sweeping marker proves frames advance.
        let progress = CGFloat(index) / CGFloat(max(1, count - 1))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: progress * (size.width - 24), y: size.height * 0.05, width: 24, height: size.height * 0.2))

        let text = "MARQUEE  frame \(index)" as CFString
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 28, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attrs))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.textPosition = CGPoint(x: 24, y: size.height * 0.3 + 24)
        CTLineDraw(line, ctx)
        return pb
    }

    private static func makeAudio(startFrame: Int, count: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let v = Float(sin(2 * .pi * 440 * Double(startFrame + i) / sampleRate)) * 0.05
            samples[2 * i] = v; samples[2 * i + 1] = v
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
                                           blockBufferOut: &block)
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}

private enum PlayerTestClipError: Error, CustomStringConvertible {
    case timedOut
    var description: String { "Generating the test clip took over 30 s (is a video encoder available?)" }
}

private actor PlayerTestClipCache {
    private var task: Task<URL, any Error>?

    func url() async throws -> URL {
        if let task { return try await task.value }
        let task = Task<URL, any Error> {
            let url = PlayerTestClip.defaultURL
            try await PlayerTestClip.generate(to: url)
            return url
        }
        self.task = task
        return try await task.value
    }
}
