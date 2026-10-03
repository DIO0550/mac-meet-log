import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct RecordingHealthTests {
    @Test func silenceAndMissingBuffersHaveDifferentThresholdsAndCooldowns() {
        var monitor = RecordingHealthMonitor()
        monitor.begin(sources: RecordingSources(), at: 0)
        for second in 1...30 {
            monitor.receive(AudioLevelSnapshot(track: .microphone, peak: 0, rms: 0), at: Double(second))
            monitor.receive(AudioLevelSnapshot(track: .systemAudio, peak: 0.5, rms: 0.1), at: Double(second))
        }
        #expect(monitor.audioWarnings(at: 29).isEmpty)
        #expect(monitor.audioWarnings(at: 30) == [.silence(.microphone)])
        #expect(monitor.audioWarnings(at: 34).isEmpty)
        #expect(monitor.audioWarnings(at: 35) == [.noBuffers(.systemAudio), .noBuffers(.microphone)])
        #expect(monitor.audioWarnings(at: 94).isEmpty)
        #expect(monitor.audioWarnings(at: 95) == [.noBuffers(.systemAudio), .noBuffers(.microphone)])
    }

    @Test func pauseDisabledSourcesAndResumeDoNotReportStaleSilence() {
        var monitor = RecordingHealthMonitor()
        let sources = RecordingSources(systemAudioEnabled: false, microphoneEnabled: true)
        monitor.begin(sources: sources, at: 0)
        #expect(monitor.audioWarnings(at: 5) == [.noBuffers(.microphone)])
        monitor.pause()
        #expect(monitor.audioWarnings(at: 1000).isEmpty)
        monitor.receive(AudioLevelSnapshot(track: .microphone, peak: 0, rms: 0), at: 1000)
        monitor.resume(sources: sources, at: 1000)
        #expect(monitor.audioWarnings(at: 1004).isEmpty)
        for second in 1001...1029 {
            monitor.receive(AudioLevelSnapshot(track: .microphone, peak: 0, rms: 0), at: Double(second))
        }
        #expect(monitor.audioWarnings(at: 1029).isEmpty)
        #expect(monitor.audioWarnings(at: 1030) == [.silence(.microphone)])
    }

    @Test func audioRecoveryRestartsSilenceWindowAndWarningDismissalDoesNotResetCooldown() {
        var monitor = RecordingHealthMonitor()
        monitor.begin(sources: RecordingSources(systemAudioEnabled: false, microphoneEnabled: true), at: 0)
        #expect(monitor.audioWarnings(at: 50) == [.noBuffers(.microphone)])
        monitor.receive(AudioLevelSnapshot(track: .microphone, peak: 0, rms: 0), at: 51)
        #expect(monitor.audioWarnings(at: 51).isEmpty)
        let firstNotice = monitor.shouldNotify(.microphoneDisconnected, at: 51)
        let noticeBeforeCooldown = monitor.shouldNotify(.microphoneDisconnected, at: 110)
        let noticeAfterCooldown = monitor.shouldNotify(.microphoneDisconnected, at: 111)
        #expect(firstNotice)
        #expect(!noticeBeforeCooldown)
        #expect(noticeAfterCooldown)
        monitor.begin(sources: RecordingSources(), at: 112)
        let noticeInNewSession = monitor.shouldNotify(.microphoneDisconnected, at: 112)
        #expect(noticeInNewSession)
    }

    @Test func capacityBoundariesDependOnVideoAndUnknownIsNotHealthy() {
        let mib: Int64 = 1_024 * 1_024
        #expect(RecordingHealthMonitor.storageStatus(bytes: nil, screenEnabled: false) == .unavailable)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 256 * mib, screenEnabled: false) == .critical)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 257 * mib, screenEnabled: false) == .low)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 512 * mib, screenEnabled: false) == .low)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 513 * mib, screenEnabled: false) == .normal)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 2048 * mib, screenEnabled: true) == .low)
        #expect(RecordingHealthMonitor.storageStatus(bytes: 2049 * mib, screenEnabled: true) == .normal)
    }

    @Test func criticalPreflightBlocksCaptureAndRapidDoubleStart() async throws {
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        var starts = 0
        var checks = 0
        let client = RecorderClient(events: events, microphoneDevices: { [] },
            start: { _, _, _ in starts += 1 }, pause: {}, resume: {}, stop: { Self.result },
            dismiss: {}, switchMicrophoneInput: { _ in }, prepareStorage: { _ in checks += 1; return 0 })
        let model = RecorderViewModel(recorder: client)
        model.setMicrophoneEnabled(false)
        model.start()
        model.start()
        try await waitUntil { !model.isStarting }
        #expect(starts == 0)
        #expect(checks == 1)
        #expect(model.presentedError != nil)
        // A failed preflight must leave the core/UI idle so retry needs no core dismiss.
        #expect(model.state == .idle)
        model.start()
        try await waitUntil { !model.isStarting }
        #expect(checks == 2)
    }

    @Test func criticalCapacityWhilePausedStopsOnceWithoutMixdownAndPreservesResult() async throws {
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        var time = 0.0
        var bytes = Int64.max
        var ordinaryStops = 0
        var safeStops = 0
        let client = RecorderClient(events: events, microphoneDevices: { [] }, start: { _, _, _ in },
            pause: {}, resume: {}, stop: { ordinaryStops += 1; return Self.result }, dismiss: {},
            switchMicrophoneInput: { _ in }, availableStorage: { bytes },
            stopPreservingTracks: { safeStops += 1; return Self.result })
        let model = RecorderViewModel(recorder: client, uptime: { time })
        continuation.yield(.stateChanged(.recording(startedAt: Date())))
        try await waitUntil { model.isRecording }
        model.checkRecordingHealth()
        continuation.yield(.stateChanged(.paused(elapsed: .seconds(1))))
        try await waitUntil { model.isPaused }
        time = 10
        bytes = 0
        model.checkRecordingHealth()
        model.checkRecordingHealth()
        try await waitUntil { model.completion != nil }
        #expect(safeStops == 1)
        #expect(ordinaryStops == 0)
        #expect(model.healthWarnings == [.criticalStorage])
    }

    @Test func testRecordingUsesTemporaryDestinationExcludesScreenAndKeepsLibraryCompletionEmpty() async throws {
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        let (timer, finishTimer) = AsyncStream<Void>.makeStream()
        defer { finishTimer.finish() }
        var testDestination = false
        var capturedSources: RecordingSources?
        let client = RecorderClient(events: events, microphoneDevices: { [] }, start: { sources, _, _ in
            capturedSources = sources
        }, pause: {}, resume: {}, stop: {
            continuation.yield(.stateChanged(.complete(Self.result)))
            return Self.result
        }, dismiss: {}, switchMicrophoneInput: { _ in }, prepareStorage: { isTest in
            testDestination = isTest
            return Int64.max
        })
        let model = RecorderViewModel(recorder: client, waitForInputTest: {
            for await _ in timer { return }
        })
        model.setMicrophoneEnabled(false)
        model.setScreenCaptureEnabled(true)
        model.startTest()
        try await waitUntil { !model.isStarting }
        // Deliver queued startup events after start returned: they must not cancel the test timer.
        continuation.yield(.stateChanged(.preparing))
        continuation.yield(.stateChanged(.recording(startedAt: Date())))
        try await waitUntil { model.isRecording }
        #expect(testDestination)
        #expect(capturedSources?.screenCaptureEnabled == false)
        #expect(capturedSources?.systemAudioEnabled == true)
        #expect(!model.addNote("not a meeting"))
        finishTimer.yield(())
        try await waitUntil { model.testCompletion != nil }
        #expect(model.completion == nil)
    }

    @Test func microphoneDisconnectWarnsOnceAndIgnoresDisabledSource() async throws {
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        let (devices, deviceContinuation) = AsyncStream<[AudioInputDevice]>.makeStream()
        defer { continuation.finish(); deviceContinuation.finish() }
        let client = RecorderClient(events: events, microphoneDevices: { AudioInputDevice.previewDevices },
            microphoneDeviceChanges: { devices }, start: { _, _, _ in }, pause: {}, resume: {},
            stop: { Self.result }, dismiss: {}, switchMicrophoneInput: { _ in })
        let model = RecorderViewModel(recorder: client, uptime: { 0 })
        try await waitUntil { model.microphoneDevices.count == 2 }
        model.selectMicrophoneDevice(id: AudioInputDevice.usbMicrophone.id)
        continuation.yield(.stateChanged(.recording(startedAt: Date())))
        try await waitUntil { model.isRecording }
        deviceContinuation.yield([.builtInMicrophone])
        try await waitUntil { !model.healthWarnings.isEmpty }
        #expect(model.healthWarnings == [.microphoneDisconnected])
        model.dismissHealthWarnings()
        deviceContinuation.yield([])
        try await waitUntil { model.microphoneDevices.isEmpty }
        #expect(model.healthWarnings.isEmpty)
        continuation.yield(.stateChanged(.idle))
        try await waitUntil { model.canEditSources }
        model.setMicrophoneEnabled(false)
        deviceContinuation.yield([.builtInMicrophone])
        try await waitUntil { !model.microphoneDevices.isEmpty }
        continuation.yield(.stateChanged(.recording(startedAt: Date())))
        try await waitUntil { model.isRecording }
        deviceContinuation.yield([])
        try await waitUntil { model.microphoneDevices.isEmpty }
        #expect(model.healthWarnings.isEmpty)
    }

    @Test func destinationRemainsPinnedAndOnlyTestDirectoryIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var selected = root.appendingPathComponent("one")
        let destination = RecordingDestination(resolve: { selected })
        _ = try destination.prepare(isTest: false)
        let first = try destination.preparedURL()
        selected = root.appendingPathComponent("two")
        #expect(try destination.preparedURL() == first)
        #expect(try destination.availableBytes() != nil)
        _ = try destination.prepare(isTest: true)
        let test = try destination.preparedURL()
        #expect(test != selected && test != first)
        _ = try destination.prepare(isTest: false)
        #expect(!FileManager.default.fileExists(atPath: test.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try destination.preparedURL() == selected)
    }

    private static var result: RecordingResult {
        RecordingResult(duration: .seconds(5), systemAudioURL: URL(fileURLWithPath: "/tmp/test_system.m4a"),
                        microphoneURL: nil, mixdown: .failed(.mixdownFailed("Skipped")), displayFileName: "test")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Recorder did not reach expected state")
    }
}
