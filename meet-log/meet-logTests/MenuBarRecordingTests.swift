import AppKit
import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct MenuBarRecordingTests {
    @Test func bothSurfacesShareCaptureAndTimestampedNotesAcrossPauseAndResume() async throws {
        let directory = try makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        var now = baseline
        let harness = MenuBarRecorderHarness(directory: directory, now: { now })
        defer { harness.events.finish() }
        let window = RecorderView(viewModel: harness.model)
        let menuBar = RecorderMenuBarView(viewModel: harness.model)
        #expect(window.viewModel === menuBar.viewModel)
        menuBar.viewModel.start()
        window.viewModel.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        #expect(harness.starts == 1)
        now = baseline.addingTimeInterval(10)
        #expect(menuBar.viewModel.addNote("from the menu bar"))
        window.viewModel.pause()
        menuBar.viewModel.pause()
        try await waitUntil { harness.model.isPaused && !harness.model.isChangingRecordingState }
        #expect(harness.pauses == 1)
        now = baseline.addingTimeInterval(100)
        #expect(menuBar.viewModel.addNote("while paused"))
        menuBar.viewModel.resume()
        window.viewModel.resume()
        try await waitUntil { harness.model.isRecording && !harness.model.isChangingRecordingState }
        #expect(harness.resumes == 1)
        now = baseline.addingTimeInterval(105)
        #expect(window.viewModel.addNote("from the main window"))
        #expect(harness.model.notes.map(\.elapsed) == [10, 10, 15])
        let notesURL = directory.appendingPathComponent("meeting_notes.json")
        #expect(try RecordingNoteStore().load(from: notesURL) == harness.model.notes)
        menuBar.viewModel.stop()
        window.viewModel.stop()
        try await waitUntil { harness.model.completion != nil && !harness.model.isStopping }
        #expect(harness.stops == 1)
        #expect(window.viewModel.state == menuBar.viewModel.state)
    }

    @Test func closingLastWindowKeepsSessionAndCancellingQuitDoesNotStopCapture() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        let delegate = MeetLogAppDelegate(recorderViewModel: harness.model, confirmTermination: { false })
        harness.model.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(harness.model.isRecording)
        #expect(!harness.model.isTerminating)
        #expect(harness.stops == 0)
        #expect(AppRootView(recorderViewModel: delegate.recorderViewModel).recorderViewModel === harness.model)
    }

    @Test func idleQuitNeedsNoConfirmation() {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        var confirmations = 0
        let delegate = MeetLogAppDelegate(recorderViewModel: harness.model, confirmTermination: {
            confirmations += 1
            return false
        })
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(confirmations == 0)
    }

    @Test func quitWaitsForStartupThenStopsOnceAndLocksBothSurfaces() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        harness.beforeStart = { for await _ in gate { return } }
        harness.model.start()
        try await waitUntil { harness.starts == 1 }
        let quit = Task { await harness.model.prepareForTermination() }
        try await waitUntil { harness.model.isTerminating }
        #expect(!harness.model.canStart)
        #expect(!harness.model.canEditSources)
        #expect(!harness.model.canStop)
        #expect(!harness.model.addNote("cannot write during quit"))
        #expect(harness.stops == 0)
        harness.model.start()
        release.yield(())
        #expect(await quit.value)
        #expect(harness.starts == 1)
        #expect(harness.stops == 1)
        #expect(harness.model.completion != nil)
        #expect(!harness.model.needsTerminationConfirmation)
    }

    @Test func quitDuringExistingSaveWaitsWithoutStoppingTwice() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        harness.model.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        harness.beforeStop = { for await _ in gate { return } }
        harness.model.stop()
        try await waitUntil { harness.stops == 1 && harness.model.isFinalizing }
        let quit = Task { await harness.model.prepareForTermination() }
        try await waitUntil { harness.model.isTerminating }
        #expect(harness.model.completion == nil)
        harness.model.stop()
        release.yield(())
        #expect(await quit.value)
        #expect(harness.stops == 1)
        #expect(harness.model.completion != nil)
    }

    @Test func failedPendingSaveCancelsQuitAndRetainsError() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        harness.model.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        harness.beforeStop = { for await _ in gate { return } }
        harness.stopError = .outputFailed("Destination disconnected")
        harness.model.stop()
        try await waitUntil { harness.stops == 1 }
        let quit = Task { await harness.model.prepareForTermination() }
        try await waitUntil { harness.model.isTerminating }
        release.yield(())
        #expect(await quit.value == false)
        #expect(!harness.model.isTerminating)
        #expect(harness.model.presentedError?.message == "Destination disconnected")
        #expect(harness.model.menuBarStatus.text == "Error")
        #expect(harness.stops == 1)
    }

    @Test func failedNotesSaveCancelsQuitAndCanBeRetried() async throws {
        let directory = try makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = MenuBarRecorderHarness(directory: directory)
        defer { harness.events.finish() }
        harness.model.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        let notesURL = directory.appendingPathComponent("meeting_notes.json")
        // A directory at the sidecar path reliably makes the atomic write fail, even as root.
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: false)
        #expect(harness.model.addNote("must survive quit"))
        #expect(harness.model.hasUnsavedNotes)
        #expect(await harness.model.prepareForTermination() == false)
        #expect(harness.model.notes.count == 1)
        #expect(harness.model.hasUnsavedNotes)
        try FileManager.default.removeItem(at: notesURL)
        #expect(await harness.model.prepareForTermination())
        #expect(harness.stops == 1)
        #expect(try RecordingNoteStore().load(from: notesURL) == harness.model.notes)
    }

    @Test func pausedQuitStopsAndSavesTheSameSession() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        harness.model.start()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        harness.model.pause()
        try await waitUntil { harness.model.isPaused && !harness.model.isChangingRecordingState }
        #expect(harness.model.needsTerminationConfirmation)
        #expect(await harness.model.prepareForTermination())
        #expect(harness.stops == 1)
        #expect(harness.model.completion != nil)
    }

    @Test func inputTestCannotPauseOrCreateMeetingNotesAndCanQuit() async throws {
        let harness = MenuBarRecorderHarness()
        defer { harness.events.finish() }
        harness.model.startTest()
        try await waitUntil { harness.model.isRecording && !harness.model.isStarting }
        #expect(!harness.model.canPause)
        #expect(!harness.model.canAddNote)
        #expect(harness.model.canStop)
        #expect(await harness.model.prepareForTermination())
        #expect(harness.model.completion == nil)
        #expect(harness.model.testCompletion != nil)
    }

    @Test func statusDistinguishesCapturePauseStopBusyAndErrors() {
        let recording = RecorderState.recording(startedAt: .now)
        #expect(RecordingMenuBarStatus(state: .idle).text == "Stopped")
        #expect(RecordingMenuBarStatus(state: recording).text == "Recording")
        #expect(RecordingMenuBarStatus(state: .paused(elapsed: .seconds(65))).text == "Paused")
        #expect(RecordingMenuBarStatus(state: .preparing).text == "Preparing")
        #expect(RecordingMenuBarStatus(state: .finalizing).text == "Saving")
        #expect(RecordingMenuBarStatus(state: .idle, isStarting: true).text == "Preparing")
        #expect(RecordingMenuBarStatus(state: recording, isStopping: true).text == "Saving")
        #expect(RecordingMenuBarStatus(state: recording, hasError: true).text == "Recording · Error")
        #expect(RecordingMenuBarStatus(state: .failed(.captureFailed("test"))).text == "Error")
    }

    private func makeSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordingJournal(startedAt: .now, stem: "meeting",
                             sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false)).save(in: directory)
        return directory
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}

@MainActor
private final class MenuBarRecorderHarness {
    let events: AsyncStream<RecorderEvent>.Continuation
    private(set) var model: RecorderViewModel!
    var starts = 0
    var pauses = 0
    var resumes = 0
    var stops = 0
    var beforeStart: (() async -> Void)?
    var beforeStop: (() async -> Void)?
    var stopError: RecorderError?

    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        let (stream, continuation) = AsyncStream<RecorderEvent>.makeStream()
        events = continuation
        let result = RecordingResult(duration: .seconds(15), systemAudioURL: nil, microphoneURL: nil,
                                     mixdown: .mixed((directory ?? FileManager.default.temporaryDirectory)
                                        .appendingPathComponent("meeting_mix.m4a")), displayFileName: "meeting_mix.m4a")
        let client = RecorderClient(events: stream, microphoneDevices: { [] }, start: { [weak self] _, _, _ in
            guard let self else { throw RecorderError.captureFailed("Test harness released") }
            self.starts += 1
            await self.beforeStart?()
            self.events.yield(.stateChanged(.recording(startedAt: now())))
        }, pause: { [weak self] in
            guard let self else { throw RecorderError.captureFailed("Test harness released") }
            self.pauses += 1
            self.events.yield(.stateChanged(.paused(elapsed: .seconds(10))))
        }, resume: { [weak self] in
            guard let self else { throw RecorderError.captureFailed("Test harness released") }
            self.resumes += 1
            self.events.yield(.stateChanged(.recording(startedAt: now())))
        }, stop: { [weak self] in
            guard let self else { throw RecorderError.captureFailed("Test harness released") }
            self.stops += 1
            self.events.yield(.stateChanged(.finalizing))
            await self.beforeStop?()
            if let stopError = self.stopError { throw stopError }
            self.events.yield(.stateChanged(.complete(result)))
            return result
        }, dismiss: {}, switchMicrophoneInput: { _ in }, sessionDirectory: { directory })
        model = RecorderViewModel(recorder: client, now: now)
        model.setMicrophoneEnabled(false)
    }
}
