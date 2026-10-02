import AVFoundation
import CoreGraphics
import Foundation
import Vision

nonisolated enum ScreenOCRError: LocalizedError {
    case invalidVideo
    case thumbnailFailed
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideo:
            return "画面動画の長さを読み取れませんでした。"
        case .thumbnailFailed:
            return "画面の変化検出用画像を作成できませんでした。"
        case let .unsupportedLanguage(locale):
            return "Vision OCRは選択した言語 (\(locale)) に対応していません。"
        }
    }
}

nonisolated struct ScreenOCRService: ScreenOCRServicing {
    func recognize(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult {
        // Image decoding and synchronous Vision work must never run on the UI actor.
        let task = Task.detached(priority: .utility) {
            try await Self.process(videoURL: videoURL, locale: locale)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func process(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult {
        let start = ContinuousClock.now
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ScreenOCRError.invalidVideo
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Preserve literal URLs, numbers and source code rather than spell-correcting them.
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = try recognitionLanguages(locale: locale, supported: supported)

        var detector = ScreenFrameChangeDetector()
        var accumulator = ScreenSegmentAccumulator()
        var sampledFrames = 0
        var recognizedFrames = 0
        var time: TimeInterval = 0
        while time < duration {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let timestamp = max(0, min(frame.actualTime.seconds, duration))
            try autoreleasepool {
                let pixels = try grayscalePixels(frame.image)
                sampledFrames += 1
                guard detector.shouldRecognize(pixels, at: timestamp) else {
                    return
                }
                try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                accumulator.observe(text, at: timestamp)
                recognizedFrames += 1
            }
            time += 2
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).components
        return ScreenOCRResult(
            segments: accumulator.finish(at: duration),
            report: ScreenOCRReport(
                sampledFrames: sampledFrames,
                recognizedFrames: recognizedFrames,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            )
        )
    }

    static func recognitionLanguages(locale: Locale, supported: [String]) throws -> [String] {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier
        let match = supported.first { $0.caseInsensitiveCompare(identifier) == .orderedSame }
            ?? supported.first { Locale(identifier: $0).language.languageCode?.identifier == language }
        guard let match else {
            throw ScreenOCRError.unsupportedLanguage(identifier)
        }
        // English supplements the selected locale for technical terms and URLs.
        return [match] + supported.filter { $0 == "en-US" && $0 != match }
    }

    private static func grayscalePixels(_ image: CGImage) throws -> [UInt8] {
        let width = 320
        let height = 180
        var pixels = [UInt8](repeating: 0, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                throw ScreenOCRError.thumbnailFailed
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
