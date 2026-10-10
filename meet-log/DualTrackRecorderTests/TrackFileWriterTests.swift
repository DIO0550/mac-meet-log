import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import DualTrackRecorder

struct TrackFileWriterTests {
    @Test(arguments: [44_100.0, 16_000.0, 96_000.0], [31, 257])
    func continuousConversionMatchesLargeBuffers(sampleRate: Double, chunkSize: Int) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = Int(sampleRate / 5)

        let reference = try renderPCM(in: directory, name: "large") { writer in
            try establishOutputFormat(writer)
            // More than 4096 output frames also exercises repeated .haveData.
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: frames)
        }
        let streamed = try renderPCM(in: directory, name: "small") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: chunkSize)
        }

        #expect(abs(reference.count - 10_080) <= 2)
        #expect(abs(Double(streamed.count) / 48_000 - 0.21) <= 2.0 / 48_000)
        expectMatchingSamples(streamed, reference)
    }

    @Test(arguments: [44_100.0, 16_000.0], [31, 53, 97, 4_410])
    func shortConvertedStreamsPreserveDuration(sampleRate: Double, chunkSize: Int) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = Int(sampleRate / 10)
        let reference = try renderPCM(in: directory, name: "large-short") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: frames)
        }
        let streamed = try renderPCM(in: directory, name: "small-short") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: chunkSize)
        }

        #expect(abs(streamed.count - 5_280) <= 2)
        expectMatchingSamples(streamed, reference)
    }

    @Test func formatChangesDrainBeforeTheNextConverterAndBeforePassthrough() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fortyFour = try renderPCM(in: directory, name: "forty-four") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 44_100, frames: 4_410, chunkSize: 97)
        }
        let sixteen = try renderPCM(in: directory, name: "sixteen") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 16_000, frames: 1_600, chunkSize: 53)
        }
        let passthrough = try renderPCM(in: directory, name: "passthrough") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 48_000, frames: 4_800, chunkSize: 101)
        }
        let switched = try renderPCM(in: directory, name: "switched") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 44_100, frames: 4_410, chunkSize: 97)
            try writeSignal(writer, sampleRate: 16_000, frames: 1_600, chunkSize: 53)
            try writeSignal(writer, sampleRate: 48_000, frames: 4_800, chunkSize: 101)
        }

        let expected = fortyFour + Array(sixteen.dropFirst(480)) + Array(passthrough.dropFirst(480))
        #expect(fortyFour.count == 5_280)
        #expect(sixteen.count == 5_280)
        #expect(passthrough.count == 5_280)
        #expect(switched.count == 14_880)
        expectMatchingSamples(switched, expected)
    }

    @Test(arguments: [44_100.0, 16_000.0], [false, true])
    func pauseKeepsPendingFramesAndExcludesPausedInput(sampleRate: Double, closeWhilePaused: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Short input leaves resampler history pending at the pause boundary.
        let frames = 127
        let reference = try renderPCM(in: directory, name: "continuous") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: sampleRate, frames: frames * 2, chunkSize: frames)
        }
        let paused = try renderPCM(in: directory, name: "paused") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: frames)
            writer.pause()
            writer.pause()
            // A different format while paused must not drain or replace state.
            try writeSignal(writer, sampleRate: 96_000, frames: 9_600, chunkSize: 9_600)
            writer.resume()
            writer.resume()
            try writeSignal(writer, sampleRate: sampleRate, frames: frames, chunkSize: frames, startFrame: frames)
            if closeWhilePaused {
                writer.pause()
            }
        }

        expectMatchingSamples(paused, reference)
    }

    @Test func channelAndInterleavingChangesUseTheFilesProcessingFormat() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = try renderPCM(in: directory, name: "mono") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 44_100, frames: 4_410, chunkSize: 113)
        }
        let converted = try renderPCM(in: directory, name: "stereo") { writer in
            try establishOutputFormat(writer)
            try writeSignal(writer, sampleRate: 44_100, frames: 4_410, chunkSize: 113, channels: 2, interleaved: true)
        }

        // Identical stereo channels should produce the same mono waveform.
        expectMatchingSamples(converted, reference)
    }

    @Test func aacTrackAndRecoverySegmentsIncludeTheDrainedDuration() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("track.m4a")
        let writer = TrackFileWriter(url: url)
        defer { _ = try? writer.close() }
        try establishOutputFormat(writer)
        try writeSignal(writer, sampleRate: 44_100, frames: 4_410, chunkSize: 31)
        try writeSignal(writer, sampleRate: 16_000, frames: 1_600, chunkSize: 31)
        writer.pause()
        #expect(try writer.close() == url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.processingFormat.sampleRate == 48_000)
        // AAC can pad a final packet; PCM tests above use a two-frame tolerance.
        #expect(abs(Double(file.length) / 48_000 - 0.21) < 0.05)

        let segments = url.deletingPathExtension().appendingPathExtension("segments")
        let files = try FileManager.default.contentsOfDirectory(at: segments, includingPropertiesForKeys: nil)
        let segment = try #require(files.first)
        #expect(files.count == 1)
        #expect(!segment.lastPathComponent.contains("partial"))
        let interval = segment.deletingPathExtension().lastPathComponent.split(separator: "-")
        let end = try #require(interval.last.flatMap { Double($0) }) / 1_000_000
        #expect(abs(end - 0.21) <= 4.0 / 48_000)
        let backup = try AVAudioFile(forReading: segment)
        #expect(abs(Double(backup.length) / 48_000 - end) < 0.05)
    }

    @Test func emptyBuffersAndClosedWriterRespectTheLifecycle() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.m4a")
        let writer = TrackFileWriter(url: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        try writer.write(empty)
        writer.pause()
        _ = try writer.close()
        writer.resume()
        #expect(throws: RecorderError.self) { try writer.write(empty) }
        #expect(throws: RecorderError.self) { try writer.close() }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 0)
        #expect(file.processingFormat.sampleRate == 44_100)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func renderPCM(
        in directory: URL,
        name: String,
        write: (TrackFileWriter) throws -> Void
    ) throws -> [Float] {
        let url = directory.appendingPathComponent("\(name).caf")
        // Exercise the real writer with lossless output, independent of AAC.
        let writer = TrackFileWriter(url: url) { url, format in
            try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }
        defer { _ = try? writer.close() }
        try write(writer)
        _ = try writer.close()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var samples: [Float] = []
        // A read can return fewer frames than requested without reaching EOF.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            let data = try #require(buffer.floatChannelData?[0])
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        #expect(AVAudioFramePosition(samples.count) == file.length)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 1)
        return samples
    }

    private func establishOutputFormat(_ writer: TrackFileWriter) throws {
        try writeSignal(writer, sampleRate: 48_000, frames: 480, chunkSize: 480)
    }

    private func writeSignal(
        _ writer: TrackFileWriter,
        sampleRate: Double,
        frames: Int,
        chunkSize: Int,
        startFrame: Int = 0,
        channels: AVAudioChannelCount = 1,
        interleaved: Bool = false
    ) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved
        ))
        for offset in stride(from: 0, to: frames, by: chunkSize) {
            let count = min(chunkSize, frames - offset)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<count {
                let time = Double(startFrame + offset + frame) / sampleRate
                let value = Float(0.3 * sin(2 * .pi * 997 * time) + 0.1 * cos(2 * .pi * 173 * time))
                for channel in 0..<Int(channels) {
                    if interleaved {
                        data[0][frame * Int(channels) + channel] = value
                        continue
                    }

                    data[channel][frame] = value
                }
            }

            try writer.write(buffer)
        }
    }

    private func expectMatchingSamples(_ actual: [Float], _ expected: [Float]) {
        #expect(actual.count == expected.count)
        // Check every sample, including all former input-buffer boundaries.
        let maximumError = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(maximumError < 0.000_01)
        #expect(actual.allSatisfy { $0.isFinite })
    }
}
