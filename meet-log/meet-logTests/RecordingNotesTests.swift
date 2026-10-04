import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct RecordingNotesTests {
    @Test func liveNoteIsPersistedBeforeStopAndCompletionMarksJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RecordingJournal(startedAt: .now, stem: "meeting",
                                       sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false))
        try journal.save(in: directory)
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        let track = directory.appendingPathComponent("meeting_system.m4a")
        let result = RecordingResult(duration: .seconds(1), systemAudioURL: track, microphoneURL: nil,
                                     mixdown: .failed(.mixdownFailed("test")), displayFileName: "meeting_mix.m4a")
        let client = RecorderClient(events: events, microphoneDevices: { [] }, start: { _, _, _ in
            continuation.yield(.stateChanged(.recording(startedAt: .now)))
        }, pause: {}, resume: {}, stop: { result }, dismiss: {}, switchMicrophoneInput: { _ in },
                                    sessionDirectory: { directory })
        let model = RecorderViewModel(recorder: client)
        model.setMicrophoneEnabled(false)
        model.start()
        try await waitUntil { model.isRecording && !model.isStarting }
        #expect(model.addNote("すぐに保存"))
        let url = directory.appendingPathComponent("meeting_notes.json")
        #expect(try RecordingNoteStore().load(from: url) == model.notes)
        #expect(!model.hasUnsavedNotes)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.completionFileName).path))
        model.stop()
        try await waitUntil { model.completion != nil && !model.isStopping }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.completionFileName).path))
    }

    @Test(arguments: [
        (65.0, "01:05"),
        (3_599.0, "59:59"),
        (3_600.0, "1:00:00"),
        (3_901.0, "1:05:01"),
        (3_902.0, "1:05:02")
    ])
    func timestampPreservesSeconds(elapsed: TimeInterval, expected: String) {
        let note = RecordingNote(elapsed: elapsed, text: "議題")
        #expect(note.timestamp == expected)
    }

    @Test func roundTripSortsNotesAndPreservesEditsAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingNoteStore()
        let url = try #require(store.url(for: directory.appendingPathComponent("meeting_mix.m4a")))
        let first = RecordingNote(elapsed: 1.25, text: "議題\n次の行")
        var second = RecordingNote(elapsed: 30, text: "次の議題")
        try store.save([second, first], to: url)
        #expect(try store.load(from: url) == [first, second])
        second.text = "編集済み"
        try store.save([second], to: url)
        #expect(try store.load(from: url) == [second])
        try store.save([], to: url)
        #expect(try store.load(from: url).isEmpty)
        #expect(store.url(for: directory.appendingPathComponent("meeting_system.m4a")) == url)
        #expect(store.url(for: directory.appendingPathComponent("meeting_microphone.m4a")) == url)
    }

    @Test func missingNotesAreEmptyButCorruptNotesAreNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = RecordingNoteStore()
        #expect(try store.load(from: url).isEmpty)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try store.load(from: url) }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(throws: (any Error).self) {
            try store.save([RecordingNote(elapsed: -1, text: "invalid")], to: url)
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func timestampsExcludePausedTimeAndPersistOnCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = directory.appendingPathComponent("meeting_mix.m4a")
        let result = RecordingResult(duration: .seconds(15), systemAudioURL: nil, microphoneURL: nil,
                                     mixdown: .mixed(track), displayFileName: track.lastPathComponent)
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        let client = RecorderClient(events: events, microphoneDevices: { [] }, start: { _, _, _ in },
                                    pause: {}, resume: {}, stop: { result }, dismiss: {},
                                    switchMicrophoneInput: { _ in })
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        var now = baseline
        let model = RecorderViewModel(recorder: client, now: { now })
        #expect(!model.addNote("idle"))
        continuation.yield(.stateChanged(.recording(startedAt: baseline)))
        try await waitUntil { model.isRecording }
        now = baseline.addingTimeInterval(10)
        #expect(model.addNote("first"))
        #expect(!model.addNote("  \n"))
        continuation.yield(.stateChanged(.paused(elapsed: .seconds(10))))
        try await waitUntil { model.isPaused }
        now = baseline.addingTimeInterval(100)
        #expect(model.addNote("paused"))
        continuation.yield(.stateChanged(.recording(startedAt: baseline)))
        try await waitUntil { model.isRecording }
        now = baseline.addingTimeInterval(105)
        #expect(model.addNote("resumed"))
        #expect(model.notes.map(\.elapsed) == [10, 10, 15])
        continuation.yield(.stateChanged(.complete(result)))
        try await waitUntil { model.completion != nil }
        #expect(!model.hasUnsavedNotes)
        let url = try #require(RecordingNoteStore().url(for: track))
        #expect(try RecordingNoteStore().load(from: url) == model.notes)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Recorder did not reach the expected state")
    }
}
