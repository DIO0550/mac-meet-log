import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import DualTrackRecorder

struct MixdownExporterIntegrationTests {
    @Test func mixesFortyEightKilohertzStereoAndFortyFourKilohertzMono() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let systemURL = try AudioFixture.write(
            in: directory.url,
            name: "system.caf",
            sampleRate: 48_000,
            channelCount: 2,
            duration: 1
        )
        let microphoneURL = try AudioFixture.write(
            in: directory.url,
            name: "microphone.caf",
            sampleRate: 44_100,
            channelCount: 1,
            duration: 1
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL
        )

        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
        #expect(format.duration >= 0.99)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func convertsCommonMicrophoneSampleRates(_ sampleRate: Double) async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let microphoneURL = try AudioFixture.write(
            in: directory.url,
            name: "microphone-\(Int(sampleRate)).caf",
            sampleRate: sampleRate,
            channelCount: 1,
            duration: 0.25
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: nil,
            microphoneURL: microphoneURL
        )

        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
        #expect(format.duration >= 0.24)
    }

    @Test func convertsSingleStereoTrackInsteadOfCopyingItsFormat() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let systemURL = try AudioFixture.write(
            in: directory.url,
            name: "system.caf",
            sampleRate: 44_100,
            channelCount: 2,
            duration: 0.25,
            interleaved: true
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: systemURL,
            microphoneURL: nil
        )

        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
        #expect(format.formatID == kAudioFormatMPEG4AAC)
    }

    @Test func keepsTheLongestInputDuration() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let systemURL = try AudioFixture.write(
            in: directory.url,
            name: "long.caf",
            sampleRate: 48_000,
            channelCount: 2,
            duration: 0.6
        )
        let microphoneURL = try AudioFixture.write(
            in: directory.url,
            name: "short.caf",
            sampleRate: 44_100,
            channelCount: 1,
            duration: 0.2
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL
        )

        #expect(format.duration >= 0.59)
        #expect(format.duration < 0.7)
    }

    @Test func ignoresAZeroDurationTrackWhenAnotherTrackHasAudio() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let emptyURL = try AudioFixture.write(
            in: directory.url,
            name: "empty.caf",
            sampleRate: 48_000,
            channelCount: 2,
            duration: 0
        )
        let microphoneURL = try AudioFixture.write(
            in: directory.url,
            name: "microphone.caf",
            sampleRate: 44_100,
            channelCount: 1,
            duration: 0.25
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: emptyURL,
            microphoneURL: microphoneURL
        )

        #expect(format.duration >= 0.24)
    }

    @Test func rejectsTwoZeroDurationTracksWithFormatDiagnostics() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let systemURL = try AudioFixture.write(
            in: directory.url,
            name: "empty-system.caf",
            sampleRate: 48_000,
            channelCount: 2,
            duration: 0
        )
        let microphoneURL = try AudioFixture.write(
            in: directory.url,
            name: "empty-microphone.caf",
            sampleRate: 44_100,
            channelCount: 1,
            duration: 0
        )

        do {
            _ = try await MixdownExporter().export(
                systemAudioURL: systemURL,
                microphoneURL: microphoneURL,
                destinationURL: directory.url.appendingPathComponent("mix.m4a")
            )
            Issue.record("Expected empty tracks to fail.")
        } catch let error as RecorderError {
            guard case let .mixdownFailed(message) = error else {
                Issue.record("Expected mixdownFailed, got \(error).")
                return
            }

            #expect(message.contains("48000.0 Hz"))
            #expect(message.contains("44100.0 Hz"))
            #expect(message.contains("filter empty tracks"))
        }
    }

    @Test func reportsUnreadableSourceAndNSErrorChain() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }
        let brokenURL = directory.url.appendingPathComponent("broken.m4a")
        try Data("not audio".utf8).write(to: brokenURL)

        do {
            _ = try await MixdownExporter().export(
                systemAudioURL: brokenURL,
                microphoneURL: nil,
                destinationURL: directory.url.appendingPathComponent("mix.m4a")
            )
            Issue.record("Expected unreadable source to fail.")
        } catch let error as RecorderError {
            guard case let .mixdownFailed(message) = error else {
                Issue.record("Expected mixdownFailed, got \(error).")
                return
            }

            #expect(message.contains("broken.m4a"))
            #expect(message.contains("domain="))
            #expect(message.contains("code="))
        }
    }

    @Test func downmixesStandardFivePointOneLayout() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let surroundURL = try AudioFixture.write(
            in: directory.url,
            name: "surround.caf",
            sampleRate: 48_000,
            channelCount: 6,
            duration: 0.25,
            layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A
        )

        let format = try await exportAndInspect(
            directory: directory,
            systemAudioURL: surroundURL,
            microphoneURL: nil
        )

        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
    }

    @Test func rejectsMultichannelInputWithoutAStandardLayout() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }

        let multichannelURL = try AudioFixture.write(
            in: directory.url,
            name: "discrete.caf",
            sampleRate: 48_000,
            channelCount: 3,
            duration: 0.25,
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3
        )

        await #expect(throws: RecorderError.self) {
            try await MixdownExporter().export(
                systemAudioURL: multichannelURL,
                microphoneURL: nil,
                destinationURL: directory.url.appendingPathComponent("mix.m4a")
            )
        }
    }

    @Test func failurePreservesExistingDestinationAndCleansStagingFiles() async throws {
        let directory = try TemporaryAudioDirectory.create()
        defer { directory.remove() }
        let brokenURL = directory.url.appendingPathComponent("broken.m4a")
        let destinationURL = directory.url.appendingPathComponent("mix.m4a")
        let existingContents = Data("existing mix".utf8)
        try Data("not audio".utf8).write(to: brokenURL)
        try existingContents.write(to: destinationURL)

        await #expect(throws: RecorderError.self) {
            try await MixdownExporter().export(
                systemAudioURL: brokenURL,
                microphoneURL: nil,
                destinationURL: destinationURL
            )
        }

        #expect(try Data(contentsOf: destinationURL) == existingContents)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(!remainingNames.contains { $0.hasPrefix(".mixing-") })
        #expect(!remainingNames.contains { $0.hasPrefix(".mix-backup-") })
    }

    private func exportAndInspect(
        directory: TemporaryAudioDirectory,
        systemAudioURL: URL?,
        microphoneURL: URL?
    ) async throws -> AudioFixture.Inspection {
        let destinationURL = directory.url.appendingPathComponent("mix.m4a")
        let result = try await MixdownExporter().export(
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            destinationURL: destinationURL
        )

        #expect(result == destinationURL)
        return try await AudioFixture.inspect(url: result)
    }
}

private struct TemporaryAudioDirectory {
    let url: URL

    static func create() throws -> TemporaryAudioDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixdownExporterIntegrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TemporaryAudioDirectory(url: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private enum AudioFixture {
    struct Inspection {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let formatID: AudioFormatID
        let duration: Double
    }

    static func write(
        in directoryURL: URL,
        name: String,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        duration: Double,
        interleaved: Bool = false,
        layoutTag: AudioChannelLayoutTag? = nil
    ) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        let format = try makeFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            interleaved: interleaved,
            layoutTag: layoutTag
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: interleaved
        )
        let totalFrames = AVAudioFramePosition((duration * sampleRate).rounded())
        var writtenFrames: AVAudioFramePosition = 0

        while writtenFrames < totalFrames {
            let frameCount = AVAudioFrameCount(min(1_024, totalFrames - writtenFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw AudioFixtureError.couldNotAllocateBuffer
            }
            buffer.frameLength = frameCount
            fill(buffer: buffer, startingAt: writtenFrames)
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(frameCount)
        }

        return url
    }

    static func inspect(url: URL) async throws -> Inspection {
        let file = try AVAudioFile(forReading: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return Inspection(
            sampleRate: file.fileFormat.sampleRate,
            channelCount: file.fileFormat.channelCount,
            formatID: file.fileFormat.streamDescription.pointee.mFormatID,
            duration: duration.seconds
        )
    }

    private static func makeFormat(
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        interleaved: Bool,
        layoutTag: AudioChannelLayoutTag?
    ) throws -> AVAudioFormat {
        if let layoutTag {
            guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
                throw AudioFixtureError.couldNotCreateFormat
            }

            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: interleaved,
                channelLayout: layout
            )
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: interleaved
        ) else {
            throw AudioFixtureError.couldNotCreateFormat
        }
        return format
    }

    private static func fill(buffer: AVAudioPCMBuffer, startingAt firstFrame: AVAudioFramePosition) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let channelCount = Int(buffer.format.channelCount)

        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else {
                continue
            }

            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<sampleCount {
                let channel = buffer.format.isInterleaved ? index % channelCount : 0
                let frame = firstFrame + AVAudioFramePosition(
                    buffer.format.isInterleaved ? index / channelCount : index
                )
                samples[index] = Float(sin(Double(frame) * 0.01 + Double(channel))) * 0.1
            }
        }
    }
}

private enum AudioFixtureError: Error {
    case couldNotCreateFormat
    case couldNotAllocateBuffer
}
