import Foundation

nonisolated struct ScreenTranscriptSegment: Codable, Equatable, Sendable {
    let text: String
    let timestamp: TimeInterval
    var duration: TimeInterval

    var timeRangeText: String {
        TranscriptSegment(text: text, timestamp: timestamp, duration: duration).timeRangeText
    }
}

nonisolated struct ScreenOCRReport: Codable, Equatable, Sendable {
    let sampledFrames: Int
    let recognizedFrames: Int
    let elapsedSeconds: TimeInterval
}

nonisolated struct ScreenOCRResult: Equatable, Sendable {
    let segments: [ScreenTranscriptSegment]
    let report: ScreenOCRReport
}

/// Compares against the last recognized frame, so gradual changes accumulate.
nonisolated struct ScreenFrameChangeDetector {
    let minimumInterval: TimeInterval
    let changedPixelFraction: Double
    let pixelDelta: Int
    private var reference: [UInt8]?
    private var lastRecognitionTime: TimeInterval?

    init(minimumInterval: TimeInterval = 2, changedPixelFraction: Double = 0.002, pixelDelta: Int = 20) {
        self.minimumInterval = minimumInterval
        self.changedPixelFraction = changedPixelFraction
        self.pixelDelta = pixelDelta
    }

    mutating func shouldRecognize(_ pixels: [UInt8], at time: TimeInterval) -> Bool {
        guard !pixels.isEmpty else {
            return false
        }
        if let lastRecognitionTime, time - lastRecognitionTime < minimumInterval {
            return false
        }
        if let reference, reference.count == pixels.count {
            let changed = zip(reference, pixels).reduce(0) { count, pair in
                count + (abs(Int(pair.0) - Int(pair.1)) >= pixelDelta ? 1 : 0)
            }
            guard Double(changed) / Double(pixels.count) >= changedPixelFraction else {
                return false
            }
        }
        reference = pixels
        lastRecognitionTime = time
        return true
    }
}

nonisolated struct ScreenSegmentAccumulator {
    private(set) var segments: [ScreenTranscriptSegment] = []
    private var activeText = ""

    mutating func observe(_ text: String, at time: TimeInterval) {
        let normalized = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard normalized != activeText else {
            return
        }
        closeActive(at: time)
        activeText = normalized
        guard !normalized.isEmpty else {
            return
        }
        segments.append(ScreenTranscriptSegment(text: normalized, timestamp: time, duration: 0))
    }

    mutating func finish(at duration: TimeInterval) -> [ScreenTranscriptSegment] {
        closeActive(at: duration)
        return segments
    }

    private mutating func closeActive(at time: TimeInterval) {
        guard !activeText.isEmpty, let last = segments.indices.last else {
            return
        }
        segments[last].duration = max(0, time - segments[last].timestamp)
    }
}

protocol ScreenOCRServicing: Sendable {
    nonisolated func recognize(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult
}

nonisolated struct ScreenTranscriptEnricher: Sendable {
    let service: ScreenOCRServicing

    func enrich(_ transcript: TranscriptResult, videoURL: URL?) async throws -> TranscriptResult {
        guard let videoURL else {
            return transcript
        }
        let result = try await service.recognize(
            videoURL: videoURL,
            locale: Locale(identifier: transcript.localeIdentifier)
        )
        return TranscriptResult(
            text: transcript.text,
            localeIdentifier: transcript.localeIdentifier,
            sourceURL: transcript.sourceURL,
            segments: transcript.segments,
            screenSegments: result.segments,
            screenOCRReport: result.report
        )
    }
}
