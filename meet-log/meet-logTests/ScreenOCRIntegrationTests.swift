import AVFoundation
import CoreText
import Foundation
import Testing
@testable import meet_log

struct ScreenOCRIntegrationTests {
    @Test func visionReadsChangedSlidesAndMeasuresProcessingTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-ocr-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeVideo(at: url)
        let result = try await ScreenOCRService().recognize(videoURL: url, locale: Locale(identifier: "en-US"))
        #expect(result.segments.count == 2)
        #expect(result.segments.first?.text.contains("PROJECT ALPHA") == true)
        #expect(result.segments.last?.text.contains("PROJECT BETA") == true)
        #expect(abs((result.segments.last?.timestamp ?? -100) - 30) < 0.2)
        #expect(result.report.sampledFrames == 30)
        #expect(result.report.recognizedFrames == 2)
        // Loose regression bound, including cold Vision model initialization on hosted CI.
        #expect(result.report.elapsedSeconds < 120)
        let measurement = "SCREEN_OCR_BENCHMARK video=60s resolution=960x540 samples=\(result.report.sampledFrames) OCR=\(result.report.recognizedFrames) elapsed=\(result.report.elapsedSeconds)s"
        print(measurement)
        try measurement.write(to: URL(fileURLWithPath: "/tmp/mac-meet-log-screen-ocr-benchmark.txt"), atomically: true, encoding: .utf8)
    }

    private nonisolated func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 960,
            AVVideoHeightKey: 540
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let alpha = try slide("PROJECT ALPHA")
        let beta = try slide("PROJECT BETA")
        for second in 0..<60 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw writer.error ?? ScreenOCRError.invalidVideo
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = second < 30 ? alpha : beta
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else {
                throw writer.error ?? ScreenOCRError.invalidVideo
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private nonisolated func slide(_ text: String) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 960, 540, kCVPixelFormatType_32ARGB, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary, &optionalBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 540,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 52, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 60, y: 280)
        CTLineDraw(line, context)
        return buffer
    }
}
