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
    @Published private(set) var isRequestingSystemAudioPermission = false
    @Published private(set) var isRequestingMicrophonePermission = false
    @Published private(set) var systemAudioPermissionState: SourcePermissionState = .unknown
    @Published private(set) var microphonePermissionState: SourcePermissionState = .unknown
    @Published private(set) var screenCaptureTargets: [ScreenCaptureTarget] = []
    @Published private(set) var selectedScreenCaptureTargetID: String?
    @Published private(set) var isLoadingScreenCaptureTargets = false
    @Published private(set) var isRequestingScreenCapturePermission = false
    @Published private(set) var screenCapturePermissionState: SourcePermissionState = .unknown

    @Published private(set) var notes: [RecordingNote] = []
    @Published private(set) var hasUnsavedNotes = false
    @Published private(set) var healthWarnings: [RecordingHealthMonitor.Warning] = []
    @Published private(set) var testCompletion: RecordingCompletion?
    @Published private(set) var isTestRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isChangingRecordingState = false
    @Published private(set) var isTerminating = false
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?
    private var commandTask: Task<Void, Never>?
    private var microphoneSwitchTask: Task<Void, Never>?
    private var didStartCapture = false
    private var healthMonitor = RecordingHealthMonitor()
    private var healthTask: Task<Void, Never>?
    private var testStopTask: Task<Void, Never>?
    private var lastStorageCheck: TimeInterval?
    private let uptime: () -> TimeInterval
    private let waitForInputTest: () async throws -> Void
    private let now: () -> Date

    private var settingsSubscription: AnyCancellable?
    private var pendingPreferences: AppPreferences?
    private var hasLoadedMicrophoneDevices = false
    private let recorder: RecorderClient
    private var activeNotesURL: URL?
    private var eventTask: Task<Void, Never>?
    private var microphoneDeviceTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var recordingBaselineElapsed: Duration = .zero
    private var recordingBaselineDate: Date?

    convenience init() {
        self.init(recorder: RecorderClient(), settings: .shared)
    }

    init(recorder: RecorderClient, now: @escaping () -> Date = Date.init, settings: AppSettings? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         waitForInputTest: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
        self.uptime = uptime
        self.waitForInputTest = waitForInputTest
        self.now = now
        self.recorder = recorder
        refreshMicrophonePermissionState()
        subscribeToRecorderEvents()
        refreshMicrophoneDevices()
        settingsSubscription = settings?.$preferences.removeDuplicates { previous, current in
            previous.systemAudioEnabled == current.systemAudioEnabled
                && previous.microphoneEnabled == current.microphoneEnabled
                && previous.microphoneDeviceUID == current.microphoneDeviceUID
        }.sink { [weak self] preferences in
            self?.pendingPreferences = preferences
            self?.applyPendingPreferences()
        }
    }

    deinit {
        healthTask?.cancel()
        testStopTask?.cancel()
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
        !isTerminating && !isStarting && !isStopping && !isChangingRecordingState && !hasUnsavedNotes && sources.hasAnyEnabledSource && !isPreparing && !isRecording && !isPaused && !isFinalizing
    }

    var canEditSources: Bool {
        !isTerminating && !isStarting && !isStopping && !isPreparing && !isRecording && !isPaused && !isFinalizing
    }

    private var canControlRecording: Bool {
        !isTerminating && !isStarting && !isStopping && !isChangingRecordingState
    }

    var canPause: Bool { canControlRecording && isRecording && !isTestRecording }
    var canResume: Bool { canControlRecording && isPaused }
    var canStop: Bool { canControlRecording && (isRecording || isPaused) }
    var canAddNote: Bool { canControlRecording && !isTestRecording && (isRecording || isPaused) }

    var needsTerminationConfirmation: Bool {
        didStartCapture || isStarting || isStopping || isPreparing || isRecording || isPaused || isFinalizing || hasUnsavedNotes
    }

    var canSelectMicrophoneInput: Bool {
        !isTerminating && !isStarting && !isStopping && sources.microphoneEnabled && !isPreparing && !isPaused && !isFinalizing && !isSwitchingMicrophoneInput
    }

    var canRequestSystemAudioPermission: Bool {
        sources.systemAudioEnabled
            && canEditSources
            && !isRequestingSystemAudioPermission
            && systemAudioPermissionState != .granted
    }

    var canRequestMicrophonePermission: Bool {
        sources.microphoneEnabled
            && canEditSources
            && !isRequestingMicrophonePermission
            && microphonePermissionState != .granted
    }

    var canRequestScreenCapturePermission: Bool {
        sources.screenCaptureEnabled
            && canEditSources
            && !isRequestingScreenCapturePermission
            && screenCapturePermissionState != .granted
    }

    var shouldShowSystemAudioPermissionRequest: Bool {
        sources.systemAudioEnabled && systemAudioPermissionState != .granted
    }

    var shouldShowMicrophonePermissionRequest: Bool {
        sources.microphoneEnabled && microphonePermissionState != .granted
    }

    var shouldShowScreenCapturePermissionRequest: Bool {
        sources.screenCaptureEnabled && screenCapturePermissionState != .granted
    }

    var selectedScreenCaptureTarget: ScreenCaptureTarget? {
        guard let selectedScreenCaptureTargetID else {
            return nil
        }

        return screenCaptureTargets.first { $0.id == selectedScreenCaptureTargetID }
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
        if isTestRecording && isRecording { return "Testing inputs (5 seconds)" }
        return switch state {
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
            microphoneEnabled: sources.microphoneEnabled,
            screenCaptureEnabled: sources.screenCaptureEnabled
        )
    }

    func setMicrophoneEnabled(_ isEnabled: Bool) {
        guard canEditSources else {
            return
        }

        sources = RecordingSources(
            systemAudioEnabled: sources.systemAudioEnabled,
            microphoneEnabled: isEnabled,
            screenCaptureEnabled: sources.screenCaptureEnabled
        )
    }

    func setScreenCaptureEnabled(_ isEnabled: Bool) {
        guard canEditSources else {
            return
        }

        sources = RecordingSources(
            systemAudioEnabled: sources.systemAudioEnabled,
            microphoneEnabled: sources.microphoneEnabled,
            screenCaptureEnabled: isEnabled
        )
        if isEnabled {
            refreshScreenCaptureTargets()
        }
    }

    func selectScreenCaptureTarget(id: String) {
        guard canEditSources, screenCaptureTargets.contains(where: { $0.id == id }) else {
            return
        }

        selectedScreenCaptureTargetID = id
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

    func requestSystemAudioPermission() {
        guard canRequestSystemAudioPermission else {
            return
        }

        Task {
            isRequestingSystemAudioPermission = true
            clearTransientPresentation()

            do {
                try await recorder.requestSystemAudioPermission()
                systemAudioPermissionState = .granted
            } catch {
                systemAudioPermissionState = .blocked
                presentNonFatal(error: error)
            }

            isRequestingSystemAudioPermission = false
        }
    }

    func requestMicrophonePermission() {
        guard canRequestMicrophonePermission else {
            return
        }

        if microphoneAuthorizationStatus == .denied || microphoneAuthorizationStatus == .restricted {
            openMicrophoneSettings()
            refreshMicrophonePermissionState()
            return
        }

        Task {
            isRequestingMicrophonePermission = true
            clearTransientPresentation()

            do {
                try await requestMicrophonePermissionIfNeeded()
                microphonePermissionState = .granted
            } catch {
                refreshMicrophonePermissionState()
                presentNonFatal(error: error)
            }

            isRequestingMicrophonePermission = false
        }
    }

    func requestScreenCapturePermission() {
        guard canRequestScreenCapturePermission else {
            return
        }

        Task {
            isRequestingScreenCapturePermission = true
            clearTransientPresentation()

            do {
                try await recorder.requestScreenCapturePermission()
                screenCapturePermissionState = .granted
                await loadScreenCaptureTargets()
            } catch {
                screenCapturePermissionState = .blocked
                presentNonFatal(
                    error: error,
                    title: "Screen Recording access is off",
                    message: error.localizedDescription,
                    recoveryAction: .screenRecordingSettings
                )
            }

            isRequestingScreenCapturePermission = false
        }
    }

    func refreshScreenCaptureTargets() {
        guard sources.screenCaptureEnabled, !isLoadingScreenCaptureTargets else {
            return
        }

        Task {
            await loadScreenCaptureTargets()
        }
    }

    func start() { start(isTest: false) }

    func startTest() { start(isTest: true) }

    private func start(isTest: Bool) {
        guard canStart else { return }
        guard !isTest || sources.systemAudioEnabled || sources.microphoneEnabled else { return }
        isStarting = true
        testStopTask?.cancel()
        isTestRecording = isTest
        testCompletion = nil
        healthWarnings = []
        healthMonitor.begin(sources: sources, at: uptime())
        startTask = Task {
            defer { isStarting = false }
            do {
                clearTransientPresentation()
                try await dismissCompletedSessionIfNeeded()
                completion = nil
                let bytes = try recorder.prepareStorage(isTest)
                let status = RecordingHealthMonitor.storageStatus(bytes: bytes, screenEnabled: !isTest && sources.screenCaptureEnabled)
                guard status != .critical else {
                    throw RecorderError.outputFailed("256 MiB or less is available. Free space before recording.")
                }
                guard status != .unavailable else {
                    throw RecorderError.outputFailed("Could not check free space at the recording destination.")
                }
                if status == .low { notifyHealth(.lowStorage) }
                try await prepareMicrophonePermissionIfNeeded()
                notes = []
                activeNotesURL = nil
                elapsed = .zero
                recordingBaselineElapsed = .zero
                recordingBaselineDate = nil
                let captureSources = RecordingSources(
                    systemAudioEnabled: sources.systemAudioEnabled,
                    microphoneEnabled: sources.microphoneEnabled,
                    screenCaptureEnabled: !isTest && sources.screenCaptureEnabled
                )
                try await recorder.start(captureSources, selectedMicrophoneSelection, selectedScreenCaptureTarget)
                didStartCapture = true
                if !isTest, let directory = await recorder.sessionDirectory() {
                    let journal = try RecordingJournal.load(in: directory)
                    activeNotesURL = directory.appendingPathComponent("\(journal.stem)_notes.json")
                    saveNotes()
                }
                healthMonitor.resume(sources: captureSources, at: uptime())
                if sources.systemAudioEnabled { systemAudioPermissionState = .granted }
                if isTest {
                    testStopTask = Task { [weak self, waitForInputTest] in
                        do { try await waitForInputTest() } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.stop()
                    }
                }
            } catch {
                stopHealthMonitoring()
                // Preflight failures have not changed the core recorder's state.
                // Capture failures publish their own failed state through the event stream.
                presentNonFatal(error: error)
            }
        }
    }

    func pause() {
        guard canPause else { return }
        runCommand {
            try await self.recorder.pause()
        }
    }

    func resume() {
        guard canResume else { return }
        runCommand {
            try await self.recorder.resume()
        }
    }

    func stop() { stop(preserveSpace: false) }

    private func stop(preserveSpace: Bool) {
        guard canStop else { return }
        beginStop(preserveSpace: preserveSpace)
    }

    private func beginStop(preserveSpace: Bool) {
        isStopping = true
        testStopTask?.cancel()
        stopHealthMonitoring()
        stopTask = Task {
            defer { isStopping = false }
            do {
                let result = try await (preserveSpace ? recorder.stopPreservingTracks() : recorder.stop())
                apply(state: .complete(result))
                didStartCapture = false
                return true
            } catch {
                present(error: error)
                return false
            }
        }
    }

    /// Wait for capture startup and any already-running save before replying to macOS's quit request.
    func prepareForTermination() async -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        defer { isTerminating = false }
        let pendingStop = isStopping ? stopTask : nil
        await startTask?.value
        await commandTask?.value
        await microphoneSwitchTask?.value
        guard await finishCaptureForTermination(pendingStop: pendingStop) else { return false }
        return persistNotes()
    }

    private func finishCaptureForTermination(pendingStop: Task<Bool, Never>?) async -> Bool {
        if let pendingStop {
            return await pendingStop.value
        }
        guard didStartCapture || isRecording || isPaused else {
            // There is no owned operation to await; never exit while capture may still be active.
            return !isPreparing && !isFinalizing
        }
        beginStop(preserveSpace: false)
        return await stopTask?.value == true
    }

    private func receiveCompletion(_ result: RecordingResult) {
        testStopTask?.cancel()
        elapsed = result.duration
        if isTestRecording {
            testCompletion = RecordingCompletion(result: result)
            return
        }
        completion = RecordingCompletion(result: result)
        saveNotes()
    }

    func dismissHealthWarnings() { healthWarnings = [] }

    private func notifyHealth(_ warning: RecordingHealthMonitor.Warning) {
        guard healthMonitor.shouldNotify(warning, at: uptime()) else { return }
        displayHealth(warning)
    }

    private func displayHealth(_ warning: RecordingHealthMonitor.Warning) {
        if !healthWarnings.contains(warning) { healthWarnings.append(warning) }
        NSSound.beep()
    }

    /// Callable with an injected clock/capacity reader for deterministic tests.
    func checkRecordingHealth() {
        guard (isRecording || isPaused), !isStarting, !isStopping else { return }
        let time = uptime()
        if isRecording {
            healthMonitor.audioWarnings(at: time).forEach(displayHealth)
        }
        guard lastStorageCheck.map({ time - $0 >= 10 }) ?? true else { return }
        lastStorageCheck = time
        let bytes = try? recorder.availableStorage()
        switch RecordingHealthMonitor.storageStatus(bytes: bytes, screenEnabled: !isTestRecording && sources.screenCaptureEnabled) {
        case .normal: break
        case .low: notifyHealth(.lowStorage)
        case .unavailable: notifyHealth(.storageUnavailable)
        case .critical:
            notifyHealth(.criticalStorage)
            stop(preserveSpace: true)
        }
    }

    private func startHealthMonitoring() {
        guard healthTask == nil else { return }
        lastStorageCheck = nil
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.checkRecordingHealth()
            }
        }
    }

    private func stopHealthMonitoring() {
        healthMonitor.pause()
        healthTask?.cancel()
        healthTask = nil
    }

    func dismiss() {
        guard !isTerminating else { return }
        guard !hasUnsavedNotes else {
            saveNotes()
            return
        }
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

    @discardableResult
    func addNote(_ text: String) -> Bool {
        guard canAddNote else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        updateElapsedFromBaseline()
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        notes.append(RecordingNote(elapsed: max(0, seconds), text: trimmed, createdAt: now()))
        hasUnsavedNotes = true
        saveNotes()
        return true
    }

    func saveNotes() {
        _ = persistNotes()
    }

    private func persistNotes() -> Bool {
        do {
            let completedNotesURL = completion?.revealURL.flatMap { RecordingNoteStore().url(for: $0) }
            let url = activeNotesURL ?? completedNotesURL
            if hasUnsavedNotes {
                guard let url else { return false }
                try RecordingNoteStore().save(notes, to: url)
                hasUnsavedNotes = false
            }
            if completion != nil, let directory = url?.deletingLastPathComponent(),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingJournal.fileName).path) {
                try RecordingJournal.markComplete(in: directory)
            }
            return !hasUnsavedNotes
        } catch {
            presentNonFatal(error: error, title: "Notes could not be saved", message: error.localizedDescription)
            return false
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func revealCompletionInFinder() {
        guard let revealURL = completion?.revealURL else {
            return
        }

        FinderReveal.reveal(fileURL: revealURL)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openRelevantSettings() {
        switch presentedError?.recoveryAction {
        case .microphoneSettings:
            openMicrophoneSettings()
        case .screenRecordingSettings:
            openScreenRecordingSettings()
        case nil:
            break
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }

        NSWorkspace.shared.open(url)
    }

    func refreshMicrophoneDevices() {
        Task {
            do {
                microphoneDevices = try await recorder.microphoneDevices()
                hasLoadedMicrophoneDevices = true
                applyPendingPreferences()
                if let selectedMicrophoneDeviceID,
                   microphoneDevices.contains(where: { $0.id == selectedMicrophoneDeviceID }) == false {
                    self.selectedMicrophoneDeviceID = nil
                }
            } catch {
                presentNonFatal(error: error)
            }
        }
    }

    private func loadScreenCaptureTargets() async {
        isLoadingScreenCaptureTargets = true
        defer { isLoadingScreenCaptureTargets = false }

        do {
            let targets = try await recorder.screenCaptureTargets()
            screenCaptureTargets = targets
            screenCapturePermissionState = .granted
            if selectedScreenCaptureTarget == nil {
                selectedScreenCaptureTargetID = targets.first?.id
            }
        } catch {
            screenCaptureTargets = []
            selectedScreenCaptureTargetID = nil
            screenCapturePermissionState = .blocked
        }
    }

    private func applyPendingPreferences() {
        guard canEditSources, let preferences = pendingPreferences else {
            return
        }
        sources = RecordingSources(
            systemAudioEnabled: preferences.systemAudioEnabled,
            microphoneEnabled: preferences.microphoneEnabled,
            screenCaptureEnabled: sources.screenCaptureEnabled
        )
        guard hasLoadedMicrophoneDevices else {
            return
        }
        selectedMicrophoneDeviceID = microphoneDevices.first {
            $0.persistentUID == preferences.microphoneDeviceUID && $0.persistentUID != nil
        }?.id
        pendingPreferences = nil
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

        microphoneSwitchTask = Task {
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
        isChangingRecordingState = true
        commandTask = Task {
            defer { isChangingRecordingState = false }
            do {
                clearTransientPresentation()
                try await command()
            } catch {
                presentNonFatal(error: error)
            }
        }
    }

    private func handle(event: RecorderEvent) {
        switch event {
        case let .recoveryCheckpointFailed(error):
            presentNonFatal(error: error, title: "Recovery checkpoint could not be saved",
                            message: "Recording continues, but the saved elapsed time may be stale. \(error.localizedDescription)")
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
        case let .screenCaptureUnavailable(error):
            let recoveryAction: RecorderErrorPresentation.RecoveryAction?
            if case .permissionDenied = error {
                screenCapturePermissionState = .blocked
                recoveryAction = .screenRecordingSettings
            } else {
                recoveryAction = nil
            }
            presentNonFatal(
                error: error,
                title: "Screen capture is unavailable",
                message: "Audio recording is continuing. \(error.localizedDescription)",
                recoveryAction: recoveryAction
            )
        }
    }

    private func apply(state newState: RecorderState) {
        guard state != newState else { return }
        let previousState = state
        state = newState

        applyPendingPreferences()

        switch newState {
        case .idle:
            stopHealthMonitoring()
            elapsed = .zero
            stopElapsedTimer()
        case .preparing:
            stopHealthMonitoring()
            stopElapsedTimer()
        case let .recording(startedAt):
            healthMonitor.resume(sources: sources, at: uptime())
            startHealthMonitoring()
            startElapsedTimer(from: startedAt, previousState: previousState)
        case let .paused(pausedElapsed):
            healthMonitor.pause()
            elapsed = pausedElapsed
            stopElapsedTimer()
        case .finalizing:
            stopHealthMonitoring()
            stopElapsedTimer()
        case let .complete(result):
            didStartCapture = false
            stopHealthMonitoring()
            stopElapsedTimer()
            receiveCompletion(result)
        case let .failed(error):
            didStartCapture = false
            testStopTask?.cancel()
            stopHealthMonitoring()
            present(error: error)
            stopElapsedTimer()
        }
    }

    private func apply(level snapshot: AudioLevelSnapshot) {
        if isRecording { healthMonitor.receive(snapshot, at: uptime()) }
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
        if isRecording { healthMonitor.reset(.microphone, at: uptime()) }
        isSwitchingMicrophoneInput = false
    }

    private func apply(microphoneDevices devices: [AudioInputDevice]) {
        let previousInput = selectedMicrophoneDeviceID ?? microphoneDevices.first(where: \.isDefault)?.id
        let currentDefault = devices.first(where: \.isDefault)?.id
        if sources.microphoneEnabled, isRecording || isPaused, let previousInput,
           !devices.contains(where: { $0.id == previousInput })
            || (selectedMicrophoneDeviceID == nil && previousInput != currentDefault) {
            notifyHealth(.microphoneDisconnected)
        }
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
            recordingBaselineDate = now()
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

        elapsed = recordingBaselineElapsed + .fromTimeInterval(now().timeIntervalSince(recordingBaselineDate))
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

        try await requestMicrophonePermissionIfNeeded()
        microphonePermissionState = .granted
    }

    private func requestMicrophonePermissionIfNeeded() async throws {
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

    private var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func refreshMicrophonePermissionState() {
        switch microphoneAuthorizationStatus {
        case .authorized:
            microphonePermissionState = .granted
        case .notDetermined:
            microphonePermissionState = .unknown
        case .denied, .restricted:
            microphonePermissionState = .blocked
        @unknown default:
            microphonePermissionState = .unknown
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

    private func presentNonFatal(
        error: Error,
        title: String? = nil,
        message: String? = nil,
        recoveryAction: RecorderErrorPresentation.RecoveryAction? = nil
    ) {
        presentedError = RecorderErrorPresentation(
            error: error,
            title: title,
            message: message,
            recoveryAction: recoveryAction
        )
    }
}

struct RecorderClient {
    let sessionDirectory: () async -> URL?
    let events: AsyncStream<RecorderEvent>
    let microphoneDevices: () async throws -> [AudioInputDevice]
    let microphoneDeviceChanges: () async -> AsyncStream<[AudioInputDevice]>
    let screenCaptureTargets: () async throws -> [ScreenCaptureTarget]
    let start: (RecordingSources, MicrophoneInputDeviceSelection, ScreenCaptureTarget?) async throws -> Void
    let pause: () async throws -> Void
    let resume: () async throws -> Void
    let stop: () async throws -> RecordingResult
    let stopPreservingTracks: () async throws -> RecordingResult
    let prepareStorage: (Bool) throws -> Int64?
    let availableStorage: () throws -> Int64?
    let dismiss: () async throws -> Void
    let switchMicrophoneInput: (MicrophoneInputDeviceSelection) async throws -> Void
    let requestSystemAudioPermission: () async throws -> Void
    let requestScreenCapturePermission: () async throws -> Void

    init() {
        self.init(recorder: DualTrackRecorder(), outputDirectory: { try AppSettings.shared.resolveOutputDirectory() })
    }

    init(recorder: DualTrackRecorder, outputDirectory: (() throws -> URL)? = nil) {
        sessionDirectory = { await recorder.currentSessionDirectory }
        let destination = RecordingDestination(resolve: {
            try outputDirectory?() ?? RecordingStorage.defaultOutputDirectoryURL
        })
        prepareStorage = { try destination.prepare(isTest: $0) }
        availableStorage = { try destination.availableBytes() }
        stopPreservingTracks = { try await recorder.stop(createMixdown: false) }
        events = recorder.events
        microphoneDevices = {
            try await recorder.microphoneInputDevices()
        }
        microphoneDeviceChanges = {
            await recorder.microphoneInputDeviceChanges()
        }
        screenCaptureTargets = {
            try await recorder.screenCaptureTargets()
        }
        start = { sources, microphoneInput, screenCaptureTarget in
            let directory = try destination.preparedURL()
            try await recorder.start(
                sources: sources,
                microphoneInput: microphoneInput,
                screenCaptureTarget: screenCaptureTarget,
                outputDirectory: directory
            )
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
        requestSystemAudioPermission = {
            try await recorder.requestSystemAudioPermission()
        }
        requestScreenCapturePermission = {
            try await recorder.requestScreenCapturePermission()
        }
    }

    init(
        events: AsyncStream<RecorderEvent>,
        microphoneDevices: @escaping () async throws -> [AudioInputDevice],
        microphoneDeviceChanges: @escaping () async -> AsyncStream<[AudioInputDevice]> = {
            AsyncStream { $0.finish() }
        },
        screenCaptureTargets: @escaping () async throws -> [ScreenCaptureTarget] = { [] },
        start: @escaping (RecordingSources, MicrophoneInputDeviceSelection, ScreenCaptureTarget?) async throws -> Void,
        pause: @escaping () async throws -> Void,
        resume: @escaping () async throws -> Void,
        stop: @escaping () async throws -> RecordingResult,
        dismiss: @escaping () async throws -> Void,
        switchMicrophoneInput: @escaping (MicrophoneInputDeviceSelection) async throws -> Void,
        requestSystemAudioPermission: @escaping () async throws -> Void = {},
        requestScreenCapturePermission: @escaping () async throws -> Void = {},
        prepareStorage: @escaping (Bool) throws -> Int64? = { _ in Int64.max },
        availableStorage: @escaping () throws -> Int64? = { Int64.max },
        stopPreservingTracks: (() async throws -> RecordingResult)? = nil,
        sessionDirectory: @escaping () async -> URL? = { nil }
    ) {
        self.sessionDirectory = sessionDirectory
        self.events = events
        self.microphoneDevices = microphoneDevices
        self.microphoneDeviceChanges = microphoneDeviceChanges
        self.screenCaptureTargets = screenCaptureTargets
        self.start = start
        self.pause = pause
        self.resume = resume
        self.stop = stop
        self.stopPreservingTracks = stopPreservingTracks ?? stop
        self.prepareStorage = prepareStorage
        self.availableStorage = availableStorage
        self.dismiss = dismiss
        self.switchMicrophoneInput = switchMicrophoneInput
        self.requestSystemAudioPermission = requestSystemAudioPermission
        self.requestScreenCapturePermission = requestScreenCapturePermission
    }
}

enum SourcePermissionState: Equatable {
    case unknown
    case granted
    case blocked
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
    let mixdown: RecordingMixdownOutcome
    let systemAudioURL: URL?
    let microphoneURL: URL?
    let screenCaptureURL: URL?
    let displayFileName: String

    var revealURL: URL? {
        mixdown.url ?? systemAudioURL ?? microphoneURL ?? screenCaptureURL
    }

    var warningMessage: String? {
        guard mixdown.error != nil else {
            return nil
        }

        return "The source tracks were saved, but the mix could not be created. Open Library to create the mix again."
    }

    init(result: RecordingResult) {
        duration = result.duration
        mixdown = result.mixdown
        systemAudioURL = result.systemAudioURL
        microphoneURL = result.microphoneURL
        screenCaptureURL = result.screenCaptureURL
        displayFileName = result.displayFileName
    }
}

struct RecorderErrorPresentation: Equatable, Identifiable {
    enum RecoveryAction: Equatable {
        case microphoneSettings
        case screenRecordingSettings
    }

    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: RecoveryAction?

    init(
        error: Error,
        title overrideTitle: String? = nil,
        message overrideMessage: String? = nil,
        recoveryAction overrideRecoveryAction: RecoveryAction? = nil
    ) {
        if let overrideTitle, let overrideMessage {
            title = overrideTitle
            message = overrideMessage
            recoveryAction = overrideRecoveryAction
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
        case let .captureFailed(message):
            title = "Audio capture could not start"
            self.message = message
            recoveryAction = nil
        case let .outputFailed(detail):
            title = "Save location is not available"
            message = detail
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
