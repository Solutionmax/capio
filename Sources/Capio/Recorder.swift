import AVFoundation
import CapioCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records one area of one display to an MP4: ScreenCaptureKit frames (and the microphone) into AVAssetWriter.
/// Pausing drops samples and shifts later timestamps back, so the file has no gap.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Failure: LocalizedError { let errorDescription: String? }

    let output: URL
    /// Microphone level 0...1, on the recorder queue.
    var onLevel: (@Sendable (Float) -> Void)?
    /// The stream stopped by itself (display gone, permission pulled).
    var onStopped: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "net.solutionmax.capio.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS = CMTime.zero
    private var offset = CMTime.zero
    private var pausedAt: CMTime?
    private var resumePending = false
    private var paused = false
    private var micMuted = false
    private var frameGap = CMTime(value: 1, timescale: 30)
    /// Pixel size of the video, known once `start` has run.
    private(set) var pixelSize = (width: 0, height: 0)

    init(output: URL) {
        self.output = output
    }

    /// `rect` is in display points with a top left origin, like the overlay. `size` caps the height; the stream scales down itself.
    func start(display: SCDisplay, rect: CGRect, scale: CGFloat, excluding: [SCWindow], microphone: Bool, fps: Int,
               size: VideoSize) async throws {
        let (w, h) = Quality.videoPixels(width: Int(rect.width * scale), height: Int(rect.height * scale), size: size)
        guard w >= 16, h >= 16 else { throw Failure(errorDescription: "The area is too small to record.") }
        pixelSize = (w, h)
        let rate = Quality.videoRate(width: w, height: h, wanted: fps)
        if rate != fps { log.info("area \(w)x\(h) is too large for \(fps) frames a second, recording at \(rate)") }
        frameGap = CMTime(value: 1, timescale: CMTimeScale(rate))
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 6
        cfg.capturesAudio = false
        cfg.captureMicrophone = microphone
        if microphone { cfg.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Quality.videoBitRate(width: w, height: h, fps: rate), AVVideoExpectedSourceFrameRateKey: rate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio); audioIn = audio }
        }
        self.writer = writer
        videoIn = video

        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    func setPaused(_ p: Bool) {
        queue.async {
            guard p != self.paused else { return }
            self.paused = p
            if p { self.pausedAt = self.lastPTS } else { self.resumePending = true }
        }
    }

    func setMicMuted(_ m: Bool) { queue.async { self.micMuted = m } }

    /// Stops and finishes the file; returns its length in seconds.
    func stop() async throws -> Double {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Double, Error>) in
            queue.async {
                guard let writer = self.writer, writer.status == .writing, let first = self.firstPTS else {
                    self.writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: self.output)
                    done.resume(throwing: Failure(errorDescription: "Nothing was recorded. Try again."))
                    return
                }
                self.videoIn?.markAsFinished()
                self.audioIn?.markAsFinished()
                let length = CMTimeGetSeconds(CMTimeSubtract(self.lastPTS, first))
                writer.finishWriting {
                    if writer.status == .completed {
                        done.resume(returning: max(length, 0))
                    } else {
                        done.resume(throwing: writer.error ?? Failure(errorDescription: "The video could not be finished."))
                    }
                }
            }
        }
    }

    // MARK: SCStreamOutput (recorder queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        switch type {
        case .screen:
            guard Self.isComplete(sb) else { return }
            if paused { return }
            if resumePending, let pausedAt {
                // The first frame after a pause lands one frame after the last one before it.
                offset = CMTimeSubtract(CMTimeSubtract(pts, pausedAt), frameGap)
                resumePending = false
                self.pausedAt = nil
            }
            let shifted = CMTimeSubtract(pts, offset)
            if firstPTS == nil {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: shifted)
                firstPTS = shifted
            }
            guard let videoIn, videoIn.isReadyForMoreMediaData, let out = Self.retimed(sb, by: offset) else { return }
            if videoIn.append(out) { lastPTS = shifted }
        case .microphone:
            onLevel?(micMuted ? 0 : Self.level(sb))
            guard !paused, !micMuted, firstPTS != nil, !resumePending, let audioIn, audioIn.isReadyForMoreMediaData,
                  let out = Self.retimed(sb, by: offset), CMSampleBufferGetPresentationTimeStamp(out) >= (firstPTS ?? .zero) else { return }
            audioIn.append(out)
        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }

    static func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let infos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }

    /// Rough RMS of a float PCM buffer, scaled for a meter.
    static func level(_ sb: CMSampleBuffer) -> Float {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length >= 4 else { return 0 }
        let n = length / 4
        let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += floats[i] * floats[i] }
        let rms = (sum / Float(max(n / 4, 1))).squareRoot()
        return min(1, rms * 6)
    }
}

enum GIFMaker {
    /// Turns a recording into a looping GIF: `fps` frames a second, at most `maxWidth` pixels wide.
    static func make(from video: URL, to gif: URL, fps: Double, maxWidth: CGFloat) async throws -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        gen.maximumSize = CGSize(width: maxWidth * 2, height: maxWidth * 2)
        let frames = max(1, Int(seconds * fps))
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw ScreenRecorder.Failure(errorDescription: "Could not create the GIF file.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var size = (width: 0, height: 0)
        for i in 0..<frames {
            let frame = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image
            let scaled = scaleDown(frame, maxWidth: Int(maxWidth))
            size = (scaled.width, scaled.height)
            CGImageDestinationAddImage(dest, scaled, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw ScreenRecorder.Failure(errorDescription: "Could not write the GIF.") }
        return size
    }

    static func scaleDown(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let h = Int(Double(image.height) * Double(maxWidth) / Double(image.width))
        guard let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        return ctx.makeImage() ?? image
    }
}
