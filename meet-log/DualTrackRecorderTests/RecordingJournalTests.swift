import AVFoundation
import Foundation
import Testing
@testable import DualTrackRecorder

struct RecordingJournalTests {
    @Test func checkpointsTrackPauseResumeAndFinalizationWithoutCompletingAppTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = FakeRecorderHarness(baseURL: root)
        let recorder = DualTrackRecorder(dependencies: harness.dependencies)
        try await recorder.start(sources: RecordingSources())
        let currentDirectory = await recorder.currentSessionDirectory
        let directory = try #require(currentDirectory)
        let initial = try RecordingJournal.load(in: directory)
        #expect(initial.phase == .recording)
        try await recorder.pause()
        let paused = try RecordingJournal.load(in: directory)
        #expect(paused.id == initial.id)
        #expect(paused.phase == .paused)
        try await recorder.resume()
        #expect(try RecordingJournal.load(in: directory).phase == .recording)
        _ = try await recorder.stop()
        #expect(try RecordingJournal.load(in: directory).phase == .finalized)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.completionFileName).path))
        try RecordingJournal.markComplete(in: directory)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.completionFileName).path))
    }

    @Test func backupClosesIntervalsWhileMainWriterIsStillOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meeting_system.m4a")
        let writer = TrackFileWriter(url: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48_000 { samples[index] = 0.1 }
        for _ in 0..<6 { try writer.write(buffer) }
        let backups = url.deletingPathExtension().appendingPathExtension("segments")
        let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        let closed = try #require(files.first { !$0.lastPathComponent.contains("partial") })
        #expect(files.count == 2)
        let saved = try AVAudioFile(forReading: closed)
        #expect(Double(saved.length) / saved.processingFormat.sampleRate >= 4.9)
        writer.pause()
        try writer.write(buffer)
        writer.resume()
        _ = try writer.close()
        let finalized = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(finalized.count == 2)
        #expect(finalized.allSatisfy { !$0.lastPathComponent.contains("partial") })
    }
}
