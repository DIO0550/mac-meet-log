import AVFoundation
import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct RecordingRecoveryTests {
    @Test func scanFindsInterruptedAndCorruptButNotCompletedOrLegacySessions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try makeSession(in: root, name: "pending")
        let complete = try makeSession(in: root, name: "complete")
        try RecordingJournal.markComplete(in: complete.directory)
        let corrupt = try directory(in: root, name: "corrupt")
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent(RecordingJournal.fileName))
        _ = try directory(in: root, name: "legacy")
        let sessions = try RecordingRecoveryStore.interrupted(in: root)
        #expect(sessions.count == 2)
        #expect(sessions.contains { $0.id == pending.id && $0.journal != nil })
        #expect(sessions.contains { $0.id == corrupt && $0.error != nil })
        #expect(try Data(contentsOf: corrupt.appendingPathComponent(RecordingJournal.fileName)) == Data("broken".utf8))
    }

    @Test func notesOnlyRecoverySurvivesRelaunchAndDoesNotOverwriteEditsOnRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let noteURL = session.directory.appendingPathComponent("meeting_notes.json")
        let notes = [RecordingNote(elapsed: 12, text: "クラッシュ前の打刻")]
        try RecordingNoteStore().save(notes, to: noteURL)
        let original = try Data(contentsOf: noteURL)
        let source = session.directory.appendingPathComponent("meeting_system.m4a")
        let brokenAudio = Data("unfinished container".utf8)
        try brokenAudio.write(to: source)
        // In-progress originals never enter the normal library scan.
        #expect(try await OutputDirectoryRecordingLibraryStore(outputDirectoryURL: root).recordings().isEmpty)
        let store = RecordingRecoveryStore()
        let first = try await store.recover(session)
        let recoveredNoteURL = session.recoveredDirectory.appendingPathComponent("meeting_notes.json")
        #expect(try RecordingNoteStore().load(from: recoveredNoteURL) == notes)
        try RecordingNoteStore().save([RecordingNote(elapsed: 12, text: "復旧後に編集")], to: recoveredNoteURL)
        let edited = try Data(contentsOf: recoveredNoteURL)
        // New store instance simulates a restart after publication but before any UI update.
        let second = try await RecordingRecoveryStore().recover(session)
        #expect(first == second)
        #expect(try Data(contentsOf: recoveredNoteURL) == edited)
        #expect(try Data(contentsOf: noteURL) == original)
        #expect(try Data(contentsOf: source) == brokenAudio)
        #expect(try RecordingRecoveryStore.interrupted(in: root).isEmpty)
        let items = try await OutputDirectoryRecordingLibraryStore(outputDirectoryURL: root).recordings()
        #expect(items.count == 1)
        #expect(items.first?.sourceSummary == "Notes only")
        #expect(items.first?.sessionDirectoryURL == session.recoveredDirectory)
    }

    @Test func failedRecoveryPreservesOriginalsAndCanBeRetried() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let originalJournal = try Data(contentsOf: session.directory.appendingPathComponent(RecordingJournal.fileName))
        let corruptNotes = session.directory.appendingPathComponent("meeting_notes.json")
        try Data("bad notes".utf8).write(to: corruptNotes)
        do {
            _ = try await RecordingRecoveryStore().recover(session)
            Issue.record("Empty recovery must fail")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: session.recoveredDirectory.path))
        #expect(try Data(contentsOf: session.directory.appendingPathComponent(RecordingJournal.fileName)) == originalJournal)
        #expect(try Data(contentsOf: corruptNotes) == Data("bad notes".utf8))
        #expect(try RecordingRecoveryStore.interrupted(in: root).count == 1)
        try makeAudio(at: session.directory.appendingPathComponent("meeting_system.m4a"))
        let report = try await RecordingRecoveryStore().recover(session)
        #expect(report.messages.contains { $0.contains("メモ: 保存ファイルが破損") })
        #expect(FileManager.default.fileExists(atPath: session.recoveredDirectory.appendingPathComponent("meeting_mix.m4a").path))
    }

    @Test func segmentedRecoveryPreservesGapsAndIgnoresUncommittedTail() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let backups = try directory(in: session.directory, name: "meeting_system.segments")
        let first = backups.appendingPathComponent("00000000000000000000-00000000000001000000.m4a")
        let last = backups.appendingPathComponent("00000000000003000000-00000000000004000000.m4a")
        try makeAudio(at: first)
        try makeAudio(at: last)
        let original = try Data(contentsOf: first)
        let tail = backups.appendingPathComponent("unclosed.partial.m4a")
        try makeAudio(at: tail) // Even a readable but uncommitted file is not trusted.
        let store = RecordingRecoveryStore()
        let inspection = try await store.inspect(session)
        #expect(inspection.system.map(\.start) == [0, 3])
        #expect(inspection.report.messages.contains { $0.contains("1.0–3.0") })
        _ = try await store.recover(session)
        let url = session.recoveredDirectory.appendingPathComponent("meeting_system.m4a")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 4) < 0.1)
        let audio = try AVAudioFile(forReading: url)
        audio.framePosition = AVAudioFramePosition(audio.processingFormat.sampleRate * 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1024))
        try audio.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0..<Int(buffer.frameLength)).allSatisfy { abs(samples[$0]) < 0.001 })
        #expect(try Data(contentsOf: first) == original)
        #expect(FileManager.default.fileExists(atPath: tail.path))
    }

    @Test func rejectsTraversalInJournalAndInvalidSegmentNames() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try RecordingJournal(startedAt: .now, stem: "../outside", sources: RecordingSources()).save(in: root)
        #expect(throws: (any Error).self) { try RecordingJournal.load(in: root) }
        for name in ["tail.partial.m4a", "nan-100.m4a", "100-10.m4a", "-1-100.m4a"] {
            #expect(RecordingRecoveryStore.segmentRange(URL(fileURLWithPath: name)) == nil)
        }
    }

    private func makeSession(in root: URL, name: String = "session") throws -> InterruptedRecording {
        let url = try directory(in: root, name: name)
        var journal = RecordingJournal(startedAt: .now, stem: "meeting",
                                       sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false))
        journal.elapsed = 15
        try journal.save(in: url)
        return InterruptedRecording(directory: url, journal: journal, error: nil)
    }

    private func directory(in root: URL = FileManager.default.temporaryDirectory, name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAudio(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48_000 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2 }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        try file.write(from: buffer)
    }
}
