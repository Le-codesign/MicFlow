import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records part of a screen to an MP4 file (H.264 video, optionally the microphone as AAC) with
/// ScreenCaptureKit. MicFlow's own windows, like the recording frame, are left out.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Called when the system stops the recording, e.g. when Screen Recording permission is taken away.
    var onStop: () -> Void = {}

    /// Everything below is used on this queue only, where the video and sound arrive.
    private let queue = DispatchQueue(label: "local.micboost.screen-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var microphone: AVCaptureSession?
    private var sessionStarted = false

    /// `rect` is in global Cocoa coordinates and within one screen.
    func start(rect: CGRect, microphone useMicrophone: Bool, to url: URL) async throws {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw Failure(errorDescription: "That area isn't on a screen.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure(errorDescription: "That screen can't be recorded.")
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        // The area within the display, counted from its top left.
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let source = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
        // Full resolution, but H.264 tops out at 4096 pixels across, so a 5K screen is scaled down.
        let scale = min(screen.backingScaleFactor, 3840 / source.width, 2160 / source.height)
        let width = Int(source.width * scale) / 2 * 2
        let height = Int(source.height * scale) / 2 * 2

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 3, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audio: AVAssetWriterInput?
        var session: AVCaptureSession?
        if useMicrophone {
            guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else {
                throw Failure(errorDescription: "No microphone found.")
            }
            let capture = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            // Plain 48 kHz mono, which the AAC encoder takes as it is.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddInput(input), capture.canAddOutput(output) else {
                throw Failure(errorDescription: "The microphone can't be recorded.")
            }
            capture.addInput(input)
            capture.addOutput(output)
            let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            soundInput.expectsMediaDataInRealTime = true
            writer.add(soundInput)
            audio = soundInput
            session = capture
        }

        guard writer.startWriting() else {
            throw Failure(errorDescription: writer.error?.localizedDescription ?? "The video file couldn't be created.")
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.microphone = session
            self.stream = stream
            self.sessionStarted = false
        }
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            queue.sync { reset() }
            throw error
        }
        session?.startRunning()
    }

    /// Finishes the file; nil if nothing was recorded.
    func stop() async -> URL? {
        let (stream, microphone) = queue.sync { (self.stream, self.microphone) }
        try? await stream?.stopCapture()
        microphone?.stopRunning()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let writer, sessionStarted else {
                    writer?.cancelWriting()
                    reset()
                    return continuation.resume(returning: nil)
                }
                // Still frames aren't sent again, so end the video now rather than at the last change.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                video?.markAsFinished()
                audio?.markAsFinished()
                reset()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? writer.outputURL : nil)
                }
            }
        }
    }

    private func reset() {
        stream = nil
        writer = nil
        video = nil
        audio = nil
        microphone = nil
        sessionStarted = false
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let writer, let video,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            sessionStarted = true
        }
        if video.isReadyForMoreMediaData { video.append(buffer) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Sound from before the first frame is dropped, so the two start together.
        guard sessionStarted, let audio, audio.isReadyForMoreMediaData else { return }
        audio.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop()
    }
}
