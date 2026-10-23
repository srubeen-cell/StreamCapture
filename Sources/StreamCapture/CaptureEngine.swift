import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noSource
    case noFrames
    case monitorUnavailable
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSource: return "Pick a screen or window to record first."
        case .noFrames: return "Nothing was captured. Check that StreamCapture is allowed under System Settings > Privacy & Security > Screen & System Audio Recording."
        case .monitorUnavailable: return "Couldn't open that output device for monitoring."
        case .writerFailed(let reason): return "Couldn't save the recording: \(reason)"
        }
    }
}

enum AudioSource { case system, microphone }

struct CaptureSettings {
    var width: Int
    var height: Int
    var fps: Int
    var videoBitrate: Int
    var showsCursor: Bool
    var includeMicrophone: Bool
    /// Part of the display to record, in display points (window mode follows the window).
    var sourceRect: CGRect? = nil
}

/// Records a ScreenCaptureKit stream (picture + system audio + optional mic) to an MP4.
/// System audio is tapped directly, so it keeps playing through your speakers as normal.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onLevel: ((AudioSource, Float) -> Void)?
    var onStopped: ((Error) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var monitor: AudioMonitor?

    private var stream: SCStream?
    private var config: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var finishing = false
    private var lastPTS = CMTime.invalid
    private var lastLevelSent: [AudioSource: CFTimeInterval] = [:]
    private var outputURL: URL?
    private var receivedFrames = 0
    private var droppedFrames = 0
    private var blackSince: CFTimeInterval?
    private var lastDiagnosticSent: CFTimeInterval = 0
    private var warnedAboutBlack = false

    // All stream outputs share one serial queue, so writer access is never concurrent.
    private let queue = DispatchQueue(label: "streamcapture.samples", qos: .userInitiated)

    func start(filter: SCContentFilter, settings: CaptureSettings, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2))
        audio.expectsMediaDataInRealTime = true

        for input in [video, audio] where writer.canAdd(input) { writer.add(input) }

        var mic: AVAssetWriterInput?
        if settings.includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); mic = input }
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        let config = SCStreamConfiguration()
        config.width = settings.width
        config.height = settings.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = settings.showsCursor
        if let rect = settings.sourceRect {
            config.sourceRect = rect
        }
        if #available(macOS 14.0, *) {
            // Fit whatever is being recorded into the fixed output frame, keeping its shape.
            config.scalesToFit = true
            config.preservesAspectRatio = true
        }
        config.backgroundColor = .black
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *) {
            config.captureMicrophone = settings.includeMicrophone
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if #available(macOS 15.0, *), settings.includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            self.micInput = mic
            self.sessionStarted = false
            self.finishing = false
            self.lastPTS = .invalid
            self.outputURL = url
            self.receivedFrames = 0
            self.droppedFrames = 0
            self.blackSince = nil
            self.lastDiagnosticSent = 0
            self.warnedAboutBlack = false
        }
        self.stream = stream
        self.config = config
        try await stream.startCapture()
    }

    /// Re-aims the capture at a window that moved, resized or went fullscreen.
    /// Pass a new filter when the window moved to another display.
    func follow(sourceRect: CGRect, filter: SCContentFilter?) async {
        guard let stream, let config else { return }
        if let filter, #available(macOS 14.0, *) {
            try? await stream.updateContentFilter(filter)
        }
        config.sourceRect = sourceRect
        try? await stream.updateConfiguration(config)
    }

    /// Stops capture and finishes the file. Returns the saved file's URL.
    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        monitor?.stop()
        return try await finishWriting()
    }

    private func finishWriting() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                guard let writer, let url = outputURL, !finishing else {
                    cont.resume(throwing: RecorderError.noFrames)
                    return
                }
                finishing = true
                guard sessionStarted else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(throwing: RecorderError.noFrames)
                    return
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                if lastPTS.isValid { writer.endSession(atSourceTime: lastPTS) }
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error"))
                    }
                }
            }
        }
    }

    private static func aacSettings(channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !finishing, let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else {
                droppedFrames += 1
                publishDiagnostics()
                return
            }
            receivedFrames += 1
            inspectFrame(sampleBuffer)
            let pts = sampleBuffer.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                if !videoInput.append(sampleBuffer) { droppedFrames += 1 }
                noteTime(pts)
            } else {
                droppedFrames += 1
            }
        case .audio:
            handleAudio(sampleBuffer, source: .system, input: audioInput)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                handleAudio(sampleBuffer, source: .microphone, input: micInput)
            }
        }
    }

    /// Samples a sparse grid of BGRA pixels at most once per second.
    /// A dark scene can also trigger this warning; it is not proof of DRM.
    private func inspectFrame(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastDiagnosticSent >= 1 else { return }
        lastDiagnosticSent = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            publishDiagnostics(); return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var dark = 0
        var total = 0
        for y in 1...8 {
            for x in 1...8 {
                let offset = (y * height / 9) * stride + (x * width / 9) * 4
                if Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < 36 { dark += 1 }
                total += 1
            }
        }
        if dark == total {
            if blackSince == nil { blackSince = now }
            if let since = blackSince, now - since >= 3, !warnedAboutBlack {
                warnedAboutBlack = true
                onDiagnostics?("Video appears black for 3+ seconds. This may be a dark scene, a capture issue, or protected content. Protected pixels cannot be restored by changing encoder settings.")
            }
        } else {
            blackSince = nil
            warnedAboutBlack = false
        }
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        // Called on the serial sample queue; avoid logging every frame.
        if receivedFrames % 60 == 0 && receivedFrames > 0 {
            NSLog("StreamCapture: received=%d dropped=%d", receivedFrames, droppedFrames)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, source: AudioSource, input: AVAssetWriterInput?) {
        if let pcm = sampleBuffer.toPCMBuffer() {
            if source == .system { monitor?.play(pcm) }
            sendLevel(AudioLevel.level(of: pcm), for: source)
        }
        // Audio before the first video frame is dropped so tracks line up.
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            noteTime(sampleBuffer.presentationTimeStamp + sampleBuffer.duration)
        }
    }

    private func noteTime(_ time: CMTime) {
        guard time.isValid else { return }
        if !lastPTS.isValid || time > lastPTS { lastPTS = time }
    }

    private func sendLevel(_ level: Float, for source: AudioSource) {
        let now = CACurrentMediaTime()
        if let last = lastLevelSent[source], now - last < 0.05 { return }
        lastLevelSent[source] = now
        onLevel?(source, level)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        monitor?.stop()
        onStopped?(error)
    }
}
