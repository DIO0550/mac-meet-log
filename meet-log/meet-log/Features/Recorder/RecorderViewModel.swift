import AppKit
import AVFoundation
import Combine
import DualTrackRecorder
import Foundation

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: Duration = .zero
    @Published private(set) var sources = RecordingSources()
    @Published private(set) var level = RecorderLevelSnapshot.empty
    @Published private(set) var waveform = RecorderWaveform.empty
    @Published private(set) var completion: RecordingCompletion?
    @Published private(set) var presentedError: RecorderErrorPresentation?
    @Published private(set) var microphoneDevices: [AudioInputDevice] = []
    @Published private(set) var selectedMicrophoneDeviceID: String?
    @Published private(set) var isSwitchingMicrophoneInput = false

    private let recorder: RecorderClient
    private var eventTask: Task<Void, Never>?
    private var microphoneDeviceTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var recordingBaselineElapsed: Duration = .zero
    private var recordingBaselineDate: Date?

    convenience init() {
        self.init(recorder: RecorderClient())
    }

    init(recorder: RecorderClient) {
        self.recorder = recorder
        subscribeToRecorderEvents()
        refreshMicrophoneDevices()
    }

    deinit {
        eventTask?.cancel()
        microphoneDeviceTask?.cancel()
        timerTask?.cancel()
    }

    var isPreparing: Bool {
        if case .preparing = state {
            return true
        }

        return false
    }

    var isRecording: Bool {
        if case .recording = state {
            return true
        }

        return false
    }

    var isPaused: Bool {
        if case .paused = state {
            return true
        }

        return false
    }

    var isFinalizing: Bool {
        if case .finalizing = state {
            return true
        }

        return false
    }

    var canStart: Bool {
        sources.hasAnyEnabledSource && !isPreparing && !isRecording && !isPaused && !isFinalizing
    }

    var canEditSources: Bool {
        !isPreparing && !isRecording && !isPaused && !isFinalizing
    }

    var canSelectMicrophoneInput: Bool {
        sources.microphoneEnabled && !isPreparing && !isPaused && !isFinalizing && !isSwitchingMicrophoneInput
    }

    var selectedMicrophoneDisplayName: String {
        guard let selectedMicrophoneDeviceID else {
            return defaultMicrophoneDeviceDisplayName
        }

        return microphoneDevices.first { $0.id == selectedMicrophoneDeviceID }?.displayName ?? "Selected microphone"
    }

    var defaultMicrophoneDeviceDisplayName: String {
        guard let defaultDevice = microphoneDevices.first(where: \.isDefault) else {
            return "System Default"
        }

        return "System Default (\(defaultDevice.name))"
    }

    var statusText: String {
        switch state {
        case .idle:
            "Ready"
        case .preparing:
            "Preparing"
        case .recording:
            "Recording"
        case .paused:
            "Paused"
        case .finalizing:
            "Saving"
        case .complete:
            "Saved"
        case .failed:
            "Needs attention"
        }
    }

    func setSystemAudioEnabled(_ isEnabled: Bool) {
        guard canEditSources else {
            return
        }

        sources = RecordingSources(
            systemAudioEnabled: isEnabled,
            microphoneEnabled: sources.microphoneEnabled
        )
    }

    func setMicrophoneEnabled(_ isEnabled: Bool) {
        guard canEditSources else {
            return
        }

        sources = RecordingSources(
            systemAudioEnabled: sources.systemAudioEnabled,
            microphoneEnabled: isEnabled
        )
    }

    func selectMicrophoneDevice(id deviceID: String?) {
        guard selectedMicrophoneDeviceID != deviceID else {
            return
        }

        guard sources.microphoneEnabled else {
            return
        }

        if isRecording {
            switchMicrophoneInput(to: deviceID)
            return
        }

        guard canSelectMicrophoneInput else {
            return
        }

        clearTransientPresentation()
        selectedMicrophoneDeviceID = deviceID
    }

    func start() {
        guard canStart else {
            present(error: RecorderError.invalidSources("Choose at least one recording source."))
            return
        }

        Task {
            do {
                clearTransientPresentation()
                try await dismissCompletedSessionIfNeeded()
                try await prepareMicrophonePermissionIfNeeded()
                completion = nil
                elapsed = .zero
                recordingBaselineElapsed = .zero
                recordingBaselineDate = nil
                try await recorder.start(sources, selectedMicrophoneSelection)
            } catch {
                present(error: error)
            }
        }
    }

    func pause() {
        runCommand {
            try await self.recorder.pause()
        }
    }

    func resume() {
        runCommand {
            try await self.recorder.resume()
        }
    }

    func stop() {
        runCommand {
            let result = try await self.recorder.stop()
            self.completion = RecordingCompletion(result: result)
            self.elapsed = result.duration
        }
    }

    func dismiss() {
        Task {
            do {
                clearTransientPresentation()
                completion = nil

                if state.requiresCoreDismiss {
                    try await recorder.dismiss()
                } else {
                    state = .idle
                    elapsed = .zero
                    stopElapsedTimer()
                }
            } catch {
                present(error: error)
            }
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func revealCompletionInFinder() {
        guard let completion else {
            return
        }

        FinderReveal.reveal(fileURL: completion.mixdownURL)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }

        NSWorkspace.shared.open(url)
    }

    func refreshMicrophoneDevices() {
        Task {
            do {
                microphoneDevices = try await recorder.microphoneDevices()
                if let selectedMicrophoneDeviceID,
                   microphoneDevices.contains(where: { $0.id == selectedMicrophoneDeviceID }) == false {
                    self.selectedMicrophoneDeviceID = nil
                }
            } catch {
                presentNonFatal(error: error)
            }
        }
    }

    private var selectedMicrophoneSelection: MicrophoneInputDeviceSelection {
        guard sources.microphoneEnabled, let selectedMicrophoneDeviceID else {
            return .systemDefault
        }

        return .device(id: selectedMicrophoneDeviceID)
    }

    private func switchMicrophoneInput(to deviceID: String?) {
        guard canSelectMicrophoneInput, isRecording else {
            return
        }

        let previousDeviceID = selectedMicrophoneDeviceID
        selectedMicrophoneDeviceID = deviceID
        isSwitchingMicrophoneInput = true

        Task {
            do {
                clearTransientPresentation()
                try await recorder.switchMicrophoneInput(selectedMicrophoneSelection)
            } catch {
                selectedMicrophoneDeviceID = previousDeviceID
                presentNonFatal(
                    error: error,
                    title: "Microphone could not switch",
                    message: "The recording is still running. Choose another microphone or try again."
                )
            }

            isSwitchingMicrophoneInput = false
        }
    }

    private func subscribeToRecorderEvents() {
        eventTask = Task { [weak self, events = recorder.events] in
            for await event in events {
                self?.handle(event: event)
            }
        }

        microphoneDeviceTask = Task { [weak self, changes = recorder.microphoneDeviceChanges] in
            let deviceChanges = await changes()
            for await devices in deviceChanges {
                self?.apply(microphoneDevices: devices)
            }
        }
    }

    private func runCommand(_ command: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                clearTransientPresentation()
                try await command()
            } catch {
                present(error: error)
            }
        }
    }

    private func handle(event: RecorderEvent) {
        switch event {
        case let .stateChanged(newState):
            apply(state: newState)
        case let .level(snapshot):
            apply(level: snapshot)
        case let .waveform(snapshot):
            apply(waveform: snapshot)
        case let .microphoneInputDeviceSwitched(selection):
            apply(microphoneInputDeviceSelection: selection)
        case let .microphoneInputDeviceSwitchFailed(selection, error):
            applyFailed(microphoneInputDeviceSelection: selection, error: error)
        }
    }

    private func apply(state newState: RecorderState) {
        let previousState = state
        state = newState

        switch newState {
        case .idle:
            elapsed = .zero
            stopElapsedTimer()
        case .preparing:
            stopElapsedTimer()
        case let .recording(startedAt):
            startElapsedTimer(from: startedAt, previousState: previousState)
        case let .paused(pausedElapsed):
            elapsed = pausedElapsed
            stopElapsedTimer()
        case .finalizing:
            stopElapsedTimer()
        case let .complete(result):
            completion = RecordingCompletion(result: result)
            elapsed = result.duration
            stopElapsedTimer()
        case let .failed(error):
            present(error: error)
            stopElapsedTimer()
        }
    }

    private func apply(level snapshot: AudioLevelSnapshot) {
        let value = min(max(Double(snapshot.peak), 0), 1)

        switch snapshot.track {
        case .systemAudio:
            level = RecorderLevelSnapshot(systemAudio: value, microphone: level.microphone)
        case .microphone:
            level = RecorderLevelSnapshot(systemAudio: level.systemAudio, microphone: value)
        }
    }

    private func apply(waveform snapshot: WaveformSnapshot) {
        waveform = RecorderWaveform(samples: snapshot.samples.map { min(max(Double($0), 0), 1) })
    }

    private func apply(microphoneInputDeviceSelection selection: MicrophoneInputDeviceSelection) {
        selectedMicrophoneDeviceID = selection.deviceID
        isSwitchingMicrophoneInput = false
    }

    private func apply(microphoneDevices devices: [AudioInputDevice]) {
        microphoneDevices = devices

        if let selectedMicrophoneDeviceID,
           devices.contains(where: { $0.id == selectedMicrophoneDeviceID }) == false {
            self.selectedMicrophoneDeviceID = nil
        }
    }

    private func applyFailed(microphoneInputDeviceSelection selection: MicrophoneInputDeviceSelection, error: RecorderError) {
        if selectedMicrophoneSelection == selection {
            selectedMicrophoneDeviceID = nil
        }

        isSwitchingMicrophoneInput = false
        presentNonFatal(
            error: error,
            title: "Microphone could not switch",
            message: "The recording is still running. Choose another microphone or try again."
        )
    }

    private func startElapsedTimer(from startedAt: Date, previousState: RecorderState) {
        if case .paused = previousState {
            recordingBaselineElapsed = elapsed
            recordingBaselineDate = Date()
        } else {
            recordingBaselineElapsed = .zero
            recordingBaselineDate = startedAt
        }

        updateElapsedFromBaseline()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.updateElapsedFromBaseline()
            }
        }
    }

    private func stopElapsedTimer() {
        timerTask?.cancel()
        timerTask = nil
        recordingBaselineDate = nil
    }

    private func updateElapsedFromBaseline() {
        guard let recordingBaselineDate else {
            return
        }

        elapsed = recordingBaselineElapsed + .fromTimeInterval(Date().timeIntervalSince(recordingBaselineDate))
    }

    private func dismissCompletedSessionIfNeeded() async throws {
        guard state.requiresCoreDismiss else {
            return
        }

        try await recorder.dismiss()
    }

    private func prepareMicrophonePermissionIfNeeded() async throws {
        guard sources.microphoneEnabled else {
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let isGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard isGranted else {
                throw RecorderError.permissionDenied("Microphone access is off.")
            }
        case .denied, .restricted:
            throw RecorderError.permissionDenied("Microphone access is off.")
        @unknown default:
            throw RecorderError.permissionDenied("Microphone access could not be confirmed.")
        }
    }

    private func clearTransientPresentation() {
        presentedError = nil
    }

    private func present(error: Error) {
        presentedError = RecorderErrorPresentation(error: error)
        if let recorderError = error as? RecorderError {
            state = .failed(recorderError)
        }
    }

    private func presentNonFatal(error: Error, title: String? = nil, message: String? = nil) {
        presentedError = RecorderErrorPresentation(error: error, title: title, message: message)
    }
}

struct RecorderClient {
    let events: AsyncStream<RecorderEvent>
    let microphoneDevices: () async throws -> [AudioInputDevice]
    let microphoneDeviceChanges: () async -> AsyncStream<[AudioInputDevice]>
    let start: (RecordingSources, MicrophoneInputDeviceSelection) async throws -> Void
    let pause: () async throws -> Void
    let resume: () async throws -> Void
    let stop: () async throws -> RecordingResult
    let dismiss: () async throws -> Void
    let switchMicrophoneInput: (MicrophoneInputDeviceSelection) async throws -> Void

    init() {
        self.init(recorder: DualTrackRecorder())
    }

    init(recorder: DualTrackRecorder) {
        events = recorder.events
        microphoneDevices = {
            try await recorder.microphoneInputDevices()
        }
        microphoneDeviceChanges = {
            await recorder.microphoneInputDeviceChanges()
        }
        start = { sources, microphoneInput in
            try await recorder.start(sources: sources, microphoneInput: microphoneInput)
        }
        pause = {
            try await recorder.pause()
        }
        resume = {
            try await recorder.resume()
        }
        stop = {
            try await recorder.stop()
        }
        dismiss = {
            try await recorder.dismiss()
        }
        switchMicrophoneInput = { selection in
            try await recorder.switchMicrophoneInput(to: selection)
        }
    }

    init(
        events: AsyncStream<RecorderEvent>,
        microphoneDevices: @escaping () async throws -> [AudioInputDevice],
        microphoneDeviceChanges: @escaping () async -> AsyncStream<[AudioInputDevice]> = {
            AsyncStream { $0.finish() }
        },
        start: @escaping (RecordingSources, MicrophoneInputDeviceSelection) async throws -> Void,
        pause: @escaping () async throws -> Void,
        resume: @escaping () async throws -> Void,
        stop: @escaping () async throws -> RecordingResult,
        dismiss: @escaping () async throws -> Void,
        switchMicrophoneInput: @escaping (MicrophoneInputDeviceSelection) async throws -> Void
    ) {
        self.events = events
        self.microphoneDevices = microphoneDevices
        self.microphoneDeviceChanges = microphoneDeviceChanges
        self.start = start
        self.pause = pause
        self.resume = resume
        self.stop = stop
        self.dismiss = dismiss
        self.switchMicrophoneInput = switchMicrophoneInput
    }
}

struct RecorderLevelSnapshot: Equatable, Sendable {
    let systemAudio: Double
    let microphone: Double

    static let empty = RecorderLevelSnapshot(systemAudio: 0, microphone: 0)
}

struct RecorderWaveform: Equatable, Sendable {
    let samples: [Double]

    static let empty = RecorderWaveform(samples: Array(repeating: 0.04, count: 28))
}

struct RecordingCompletion: Equatable, Identifiable {
    let id = UUID()
    let duration: Duration
    let mixdownURL: URL
    let displayFileName: String

    init(result: RecordingResult) {
        duration = result.duration
        mixdownURL = result.mixdownURL
        displayFileName = result.displayFileName
    }
}

struct RecorderErrorPresentation: Equatable, Identifiable {
    enum RecoveryAction: Equatable {
        case microphoneSettings
    }

    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: RecoveryAction?

    init(error: Error, title overrideTitle: String? = nil, message overrideMessage: String? = nil) {
        if let overrideTitle, let overrideMessage {
            title = overrideTitle
            message = overrideMessage
            recoveryAction = nil
            return
        }

        guard let recorderError = error as? RecorderError else {
            title = "Recording could not continue"
            message = "Something went wrong. Try again when you are ready."
            recoveryAction = nil
            return
        }

        switch recorderError {
        case .permissionDenied:
            title = "Microphone access is off"
            message = "Allow microphone access in System Settings, then start recording again."
            recoveryAction = .microphoneSettings
        case .captureFailed:
            title = "Audio capture could not start"
            message = "Check your audio devices and try recording again."
            recoveryAction = nil
        case .outputFailed:
            title = "Save location is not available"
            message = "The recording folder could not be prepared. Check your Music folder and try again."
            recoveryAction = nil
        case .invalidState:
            title = "Recorder is busy"
            message = "Wait for the current action to finish, then try again."
            recoveryAction = nil
        case .invalidSources:
            title = "Choose a source"
            message = "Turn on system audio, microphone, or both before starting."
            recoveryAction = nil
        case .audioInputDeviceUnavailable:
            title = "Microphone is not available"
            message = "Choose another microphone or reconnect the selected input device."
            recoveryAction = nil
        case .microphoneNotEnabled:
            title = "Microphone is off"
            message = "Turn on microphone recording before choosing an input device."
            recoveryAction = nil
        case .mixdownFailed:
            title = "Mixdown could not be saved"
            message = "The source tracks may still be available. Try recording again."
            recoveryAction = nil
        }
    }
}

enum FinderReveal {
    static func reveal(fileURL: URL) {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return
        }

        let folderURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.open(folderURL)
            return
        }

        NSWorkspace.shared.open(folderURL.deletingLastPathComponent())
    }
}

extension Duration {
    var recorderDisplayString: String {
        let totalSeconds = max(0, Int(components.seconds))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func fromTimeInterval(_ interval: TimeInterval) -> Duration {
        let clampedInterval = max(interval, 0)
        let wholeSeconds = Int64(clampedInterval.rounded(.down))
        let fractionalSeconds = clampedInterval - TimeInterval(wholeSeconds)

        return .seconds(wholeSeconds) + .nanoseconds(Int64((fractionalSeconds * 1_000_000_000).rounded()))
    }
}

private extension RecorderState {
    var requiresCoreDismiss: Bool {
        switch self {
        case .complete, .failed:
            true
        case .idle, .preparing, .recording, .paused, .finalizing:
            false
        }
    }
}
