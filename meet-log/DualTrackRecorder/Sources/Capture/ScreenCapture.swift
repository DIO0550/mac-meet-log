import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public struct ScreenCaptureTarget: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case display
        case window
        case application
    }

    public let id: String
    public let kind: Kind
    public let name: String
    public let detail: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    let displayID: UInt32?
    let windowID: UInt32?
    let processID: Int32?

    public init(
        id: String,
        kind: Kind,
        name: String,
        detail: String = "",
        pixelWidth: Int,
        pixelHeight: Int,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        processID: Int32? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayID = displayID
        self.windowID = windowID
        self.processID = processID
    }
}

public struct ScreenCaptureVideoConfiguration: Equatable, Sendable {
    public static let `default` = ScreenCaptureVideoConfiguration()

    public let framesPerSecond: Int
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let averageBitRate: Int

    public init(
        framesPerSecond: Int = 15,
        maximumWidth: Int = 1_920,
        maximumHeight: Int = 1_080,
        averageBitRate: Int = 4_000_000
    ) {
        self.framesPerSecond = framesPerSecond
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.averageBitRate = averageBitRate
    }

    public var estimatedBytesPerHour: Int64 {
        Int64(averageBitRate) * 3_600 / 8
    }
}

protocol ScreenCapturing: AnyObject {
    func start() async throws
    func pause()
    func resume()
    func stop() async throws -> URL
}

enum ScreenCaptureAccess {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func request() -> Bool {
        isGranted || CGRequestScreenCaptureAccess()
    }
}

enum ScreenCaptureTargetProvider {
    static func targets() async throws -> [ScreenCaptureTarget] {
        let content = try await shareableContent()
        let displayTargets = content.displays.map { display in
            ScreenCaptureTarget(
                id: "display:\(display.displayID)",
                kind: .display,
                name: "Display \(display.displayID)",
                detail: "Entire display",
                pixelWidth: display.width,
                pixelHeight: display.height,
                displayID: display.displayID
            )
        }
        let windowTargets = content.windows.compactMap { window -> ScreenCaptureTarget? in
            guard window.isOnScreen,
                  let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return nil
            }

            return ScreenCaptureTarget(
                id: "window:\(window.windowID)",
                kind: .window,
                name: title,
                detail: window.owningApplication?.applicationName ?? "Window",
                pixelWidth: max(Int(window.frame.width.rounded()), 2),
                pixelHeight: max(Int(window.frame.height.rounded()), 2),
                windowID: window.windowID
            )
        }

        let primaryDisplay = content.displays.first
        let applicationTargets = content.applications.compactMap { application -> ScreenCaptureTarget? in
            guard let primaryDisplay else {
                return nil
            }

            return ScreenCaptureTarget(
                id: "application:\(application.processID):\(primaryDisplay.displayID)",
                kind: .application,
                name: application.applicationName,
                detail: "Application on Display \(primaryDisplay.displayID)",
                pixelWidth: primaryDisplay.width,
                pixelHeight: primaryDisplay.height,
                displayID: primaryDisplay.displayID,
                processID: application.processID
            )
        }

        return (displayTargets + applicationTargets + windowTargets).sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            return Self.sortOrder(lhs.kind) < Self.sortOrder(rhs.kind)
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied(
                "Screen Recording access is off. Allow meet-log in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
    }

    private static func sortOrder(_ kind: ScreenCaptureTarget.Kind) -> Int {
        switch kind {
        case .display:
            return 0
        case .application:
            return 1
        case .window:
            return 2
        }
    }
}

final class ScreenCaptureRecorder: NSObject, ScreenCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let target: ScreenCaptureTarget
    private let outputURL: URL
    private let videoConfiguration: ScreenCaptureVideoConfiguration
    private let queue = DispatchQueue(label: "DualTrackRecorder.screen-capture.frames")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var firstSourceTimestamp: CMTime?
    private var lastAcceptedSourceTimestamp: CMTime?
    private var accumulatedPausedDuration = CMTime.zero
    private var isPaused = false
    private var isResumePending = false
    private var didAppendFrame = false
    private var appendError: Error?

    init(
        target: ScreenCaptureTarget,
        outputURL: URL,
        videoConfiguration: ScreenCaptureVideoConfiguration
    ) {
        self.target = target
        self.outputURL = outputURL
        self.videoConfiguration = videoConfiguration
    }

    func start() async throws {
        let content = try await ScreenCaptureTargetProvider.shareableContent()
        let filter = try contentFilter(from: content)
        let dimensions = scaledDimensions(width: target.pixelWidth, height: target.pixelHeight)
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = dimensions.width
        streamConfiguration.height = dimensions.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(videoConfiguration.framesPerSecond)
        )
        streamConfiguration.queueDepth = 5
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Keep completed fragments readable if finishWriting is never reached.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoConfiguration.averageBitRate,
                    AVVideoExpectedSourceFrameRateKey: videoConfiguration.framesPerSecond
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.outputFailed("Could not configure the screen recording writer.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.outputFailed(
                "Could not start the screen recording writer. \(writer.error?.localizedDescription ?? "Unknown error.")"
            )
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.writer = writer
        self.writerInput = input
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.writer = nil
            self.writerInput = nil
            throw RecorderError.captureFailed("Could not start screen capture. \(error.localizedDescription)")
        }
    }

    func pause() {
        queue.async { [weak self] in
            self?.isPaused = true
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, isPaused else {
                return
            }

            isPaused = false
            isResumePending = true
        }
    }

    func stop() async throws -> URL {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                throw RecorderError.captureFailed("Could not stop screen capture. \(error.localizedDescription)")
            }
        }
        self.stream = nil

        let finalState = queue.sync { () -> (AVAssetWriter?, AVAssetWriterInput?, Bool, Error?) in
            (writer, writerInput, didAppendFrame, appendError)
        }
        guard let writer = finalState.0, let input = finalState.1 else {
            throw RecorderError.outputFailed("Screen recording was not started.")
        }
        if let appendError = finalState.3 {
            throw RecorderError.outputFailed("Could not save a screen frame. \(appendError.localizedDescription)")
        }
        guard finalState.2 else {
            throw RecorderError.outputFailed("No screen frames were captured.")
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw RecorderError.outputFailed(
                "Could not finalize the screen recording. \(writer.error?.localizedDescription ?? "Unknown error.")"
            )
        }

        self.writer = nil
        self.writerInput = nil
        return outputURL
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              !isPaused,
              appendError == nil,
              let writer,
              let writerInput,
              writerInput.isReadyForMoreMediaData else {
            return
        }

        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isResumePending, let lastAcceptedSourceTimestamp {
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(videoConfiguration.framesPerSecond))
            let expectedTimestamp = CMTimeAdd(lastAcceptedSourceTimestamp, frameDuration)
            let pauseDuration = CMTimeSubtract(sourceTimestamp, expectedTimestamp)
            if CMTimeCompare(pauseDuration, .zero) > 0 {
                accumulatedPausedDuration = CMTimeAdd(accumulatedPausedDuration, pauseDuration)
            }
            isResumePending = false
        }

        if firstSourceTimestamp == nil {
            firstSourceTimestamp = sourceTimestamp
            writer.startSession(atSourceTime: .zero)
        }
        guard let firstSourceTimestamp,
              let retimed = retimedSampleBuffer(
                sampleBuffer,
                offset: CMTimeAdd(firstSourceTimestamp, accumulatedPausedDuration)
              ) else {
            return
        }

        if writerInput.append(retimed) {
            didAppendFrame = true
            lastAcceptedSourceTimestamp = sourceTimestamp
        } else {
            appendError = writer.error ?? RecorderError.outputFailed("The screen writer rejected a frame.")
        }
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            self?.appendError = error
        }
    }

    private func contentFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch target.kind {
        case .display:
            guard let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.captureFailed("The selected display is no longer available.")
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let windowID = target.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.captureFailed("The selected window is no longer available.")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .application:
            guard let processID = target.processID,
                  let application = content.applications.first(where: { $0.processID == processID }),
                  let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.captureFailed("The selected application is no longer available.")
            }
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }
    }

    private func scaledDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let safeWidth = max(width, 2)
        let safeHeight = max(height, 2)
        let scale = min(
            1,
            min(
                Double(videoConfiguration.maximumWidth) / Double(safeWidth),
                Double(videoConfiguration.maximumHeight) / Double(safeHeight)
            )
        )
        return (
            max(Int((Double(safeWidth) * scale).rounded(.down)) / 2 * 2, 2),
            max(Int((Double(safeHeight) * scale).rounded(.down)) / 2 * 2, 2)
        )
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var timingCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        ) == noErr else {
            return nil
        }

        var timing = Array(repeating: CMSampleTimingInfo(), count: timingCount)
        let readStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &timingCount
            )
        }
        guard readStatus == noErr else {
            return nil
        }

        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &output
            )
        }
        return status == noErr ? output : nil
    }
}
