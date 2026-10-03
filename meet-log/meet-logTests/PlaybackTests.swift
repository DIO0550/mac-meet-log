import AVFoundation
import Foundation
import Testing
@testable import meet_log

@MainActor
@Suite(.serialized)
struct PlaybackTests {
    @Test func clampsNegativeAndPastEndButRejectsInvalidTimes() {
        #expect(PlaybackTimeline.position(-5, duration: 30) == 0)
        #expect(PlaybackTimeline.position(12.5, duration: 30) == 12.5)
        #expect(PlaybackTimeline.position(30, duration: 30) == 30)
        #expect(PlaybackTimeline.position(100, duration: 30) == 30)
        #expect(PlaybackTimeline.position(.nan, duration: 30) == nil)
        #expect(PlaybackTimeline.position(.infinity, duration: 30) == nil)
        #expect(PlaybackTimeline.position(1, duration: .infinity) == nil)
        #expect(PlaybackTimeline.position(1, duration: 0) == nil)
        #expect(PlaybackTimeline.label(0) == "00:00")
        #expect(PlaybackTimeline.label(225) == "03:45")
        #expect(PlaybackTimeline.label(3599) == "59:59")
        #expect(PlaybackTimeline.label(3600) == "1:00:00")
        #expect(PlaybackTimeline.label(3661) == "1:01:01")
        #expect(TranscriptSegment(text: "Invalid", timestamp: .infinity, duration: 1).timeRangeText == "--:--–--:--")
        #expect(RecordingNote(elapsed: .greatestFiniteMagnitude, text: "Invalid").timestamp == "--:--")
    }

    @Test func audioOnlyImportSupportsSeekSpeedAndEndWithoutWrapping() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MeetingPlaybackController()
        defer { controller.stop() }
        await controller.load(PlaybackSource(audioURLs: [url]))
        #expect(controller.canPlay)
        #expect(!controller.hasVideo)
        #expect(abs(controller.duration - 2) < 0.01)
        controller.jump(to: 0.7)
        #expect(controller.position == 0.7)
        #expect(controller.isPlaying)
        controller.setSpeed(1.5)
        #expect(controller.speed == 1.5)
        controller.setSpeed(.nan)
        #expect(controller.speed == 1.5)
        controller.jump(to: 100)
        #expect(controller.position == controller.duration)
        #expect(!controller.isPlaying)
        controller.jump(to: .nan)
        #expect(controller.position == controller.duration)
        controller.toggle()
        #expect(controller.position == 0)
        #expect(controller.isPlaying)
        controller.pause()
        #expect(!controller.isPlaying)
    }

    @Test func missingVideoKeepsAudioAndAllMissingFailsSafely() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = url.appendingPathExtension("missing")
        let controller = MeetingPlaybackController()
        defer { controller.stop() }
        await controller.load(PlaybackSource(audioURLs: [url], videoURL: missing))
        #expect(controller.canPlay)
        #expect(!controller.hasVideo)
        #expect(controller.availability.contains("画面動画を利用できません"))
        await controller.load(PlaybackSource(audioURLs: [missing], videoURL: missing))
        #expect(!controller.canPlay)
        #expect(controller.errorMessage != nil)
        #expect(controller.player.currentItem == nil)
        controller.jump(to: 10)
        #expect(controller.position == 0)
    }

    @Test func sourceTracksOverlapInsteadOfConcatenating() async throws {
        let first = try makeAudio()
        let second = try makeAudio()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let loaded = try await PlaybackMediaLoader().load(PlaybackSource(audioURLs: [first, second]))
        let tracks = try await loaded.composition.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        #expect(abs(loaded.composition.duration.seconds - 2) < 0.01)
        for track in tracks {
            let range = try await track.load(.timeRange)
            #expect(range.start.seconds == 0)
        }
    }

    @Test func lateLoadCannotReplaceNewMeetingAndSwitchStopsOldAudio() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = PlaybackSource(audioURLs: [url])
        let media = try await PlaybackMediaLoader().load(source)
        let loader = SuspendedPlaybackLoader()
        let controller = MeetingPlaybackController(loader: loader)
        defer { controller.stop() }
        let first = Task { await controller.load(source) }
        while loader.requests.count < 1 {
            await Task.yield()
        }
        let second = Task { await controller.load(source) }
        while loader.requests.count < 2 {
            await Task.yield()
        }
        loader.requests[1].resume(returning: media)
        await second.value
        controller.jump(to: 0.5)
        let current = controller.player.currentItem
        loader.requests[0].resume(returning: media)
        await first.value
        #expect(controller.player.currentItem === current)
        #expect(controller.position == 0.5)
        let third = Task { await controller.load(source) }
        while loader.requests.count < 3 {
            await Task.yield()
        }
        #expect(controller.player.rate == 0)
        #expect(controller.player.currentItem == nil)
        #expect(!controller.isPlaying)
        controller.stop()
        loader.requests[2].resume(returning: media)
        await third.value
        #expect(controller.player.currentItem == nil)
        #expect(!controller.canPlay)
    }

    @Test func audioAndVideoKeepSameRecordedTimeRanges() async throws {
        let audio = try makeAudio()
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: video)
        }
        try await makeVideo(at: video)
        let loaded = try await PlaybackMediaLoader().load(PlaybackSource(audioURLs: [audio], videoURL: video))
        #expect(loaded.hasVideo)
        #expect(abs(loaded.composition.duration.seconds - 2) < 0.01)
        let sourceTrack = try #require(try await AVURLAsset(url: video).loadTracks(withMediaType: .video).first)
        let resultTrack = try #require(try await loaded.composition.loadTracks(withMediaType: .video).first)
        let sourceRange = try await sourceTrack.load(.timeRange)
        let segment = try #require(resultTrack.segments.first(where: { !$0.isEmpty }))
        #expect(segment.timeMapping.source == sourceRange)
        #expect(segment.timeMapping.target == sourceRange)
        let videoOnly = try await PlaybackMediaLoader().load(PlaybackSource(audioURLs: [], videoURL: video))
        #expect(videoOnly.hasVideo)
        #expect(videoOnly.availability.contains("画面のみ"))
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16000 {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 8000)) * 0.1
        }
        try file.write(from: buffer)
        return url
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB,
                                  nil, &optionalBuffer) == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(pixels, 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // The leading half-second must not be silently shifted to zero by playback.
        for frame in 5..<20 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 10))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

@MainActor
private final class SuspendedPlaybackLoader: PlaybackMediaLoading {
    var requests: [CheckedContinuation<PlaybackMedia, Error>] = []

    func load(_ source: PlaybackSource) async throws -> PlaybackMedia {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
}
