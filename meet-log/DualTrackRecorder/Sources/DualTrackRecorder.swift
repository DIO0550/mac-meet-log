import Foundation

public actor DualTrackRecorder {
    private let configuration: RecorderConfiguration
    private let dependencies: RecorderDependencies
    private let session: RecordingSession
    private let eventStream: AsyncStream<RecorderEvent>
    private let eventContinuation: AsyncStream<RecorderEvent>.Continuation
    private var activeCaptureSession: ActiveCaptureSession?

    public nonisolated var events: AsyncStream<RecorderEvent> {
        eventStream
    }

    public init(configuration: RecorderConfiguration = .default) {
        self.init(configuration: configuration, dependencies: .live)
    }

    init(configuration: RecorderConfiguration = .default, dependencies: RecorderDependencies) {
        let (eventStream, eventContinuation) = Self.makeEventStream()

        self.configuration = configuration
        self.dependencies = dependencies
        self.session = RecordingSession()
        self.eventStream = eventStream
        self.eventContinuation = eventContinuation
    }

    public func start(
        sources: RecordingSources,
        microphoneInput: MicrophoneInputDeviceSelection = .systemDefault,
        screenCaptureTarget: ScreenCaptureTarget? = nil,
        outputDirectory: URL? = nil
    ) async throws {
        let states = try await session.start(sources: sources)
        publish(states)

        do {
            activeCaptureSession = try await makeCaptureSession(
                sources: sources,
                microphoneInput: microphoneInput,
                screenCaptureTarget: screenCaptureTarget,
                outputDirectoryURL: outputDirectory ?? configuration.outputDirectory
            )
            if let screenCaptureError = try await activeCaptureSession?.start() {
                eventContinuation.yield(.screenCaptureUnavailable(screenCaptureError))
            }
        } catch {
            activeCaptureSession?.stopImmediately()
            activeCaptureSession = nil
            let recorderError = normalize(error, fallback: "Could not start recording.")
            publish(await session.fail(with: recorderError))
            throw recorderError
        }
    }

    public func microphoneInputDevices() throws -> [AudioInputDevice] {
        try dependencies.microphoneDeviceProvider.devices()
    }

    public func microphoneInputDeviceChanges() -> AsyncStream<[AudioInputDevice]> {
        dependencies.microphoneDeviceProvider.deviceChanges()
    }

    public func screenCaptureTargets() async throws -> [ScreenCaptureTarget] {
        try await dependencies.screenCaptureTargets()
    }

    public func requestScreenCapturePermission() throws {
        guard dependencies.requestScreenCapturePermission() else {
            throw RecorderError.permissionDenied(
                "Screen Recording access is off. Allow meet-log in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
    }

    public func requestSystemAudioPermission() async throws {
        let capture = dependencies.systemAudioCaptureFactory { _, _ in }

        do {
            try await capture.start()
            capture.stop()
        } catch {
            capture.stop()
            throw normalize(error, fallback: "Could not request system audio access.")
        }
    }

    public func switchMicrophoneInput(to selection: MicrophoneInputDeviceSelection) async throws {
        let currentState = await session.state

        guard currentState.allowsMicrophoneInputSwitch else {
            throw RecorderError.invalidState(
                operation: "switch microphone input",
                state: currentState.debugName
            )
        }

        guard let activeCaptureSession else {
            throw RecorderError.invalidState(operation: "switch microphone input", state: "idle")
        }

        do {
            try await activeCaptureSession.switchMicrophoneCapture { processor in
                dependencies.microphoneCaptureFactory(selection) { buffer, time in
                    processor.append(buffer, time: time)
                }
            }
            eventContinuation.yield(.microphoneInputDeviceSwitched(selection))
        } catch {
            let recorderError = normalize(error, fallback: "Could not switch microphone input.")
            eventContinuation.yield(.microphoneInputDeviceSwitchFailed(selection, recorderError))
            throw recorderError
        }
    }

    public func pause() async throws {
        let state = try await session.pause()
        activeCaptureSession?.pause()
        publish(state)
    }

    public func resume() async throws {
        let state = try await session.resume()
        activeCaptureSession?.resume()
        publish(state)
    }

    public func stop(createMixdown: Bool = true) async throws -> RecordingResult {
        let finalizing = try await session.startFinalizing()
        publish(finalizing)

        guard let activeCaptureSession else {
            let error = RecorderError.invalidState(operation: "stop capture", state: "idle")
            publish(await session.fail(with: error))
            throw error
        }

        do {
            let screenCaptureOutcome = await activeCaptureSession.stop()
            if let error = screenCaptureOutcome.error {
                eventContinuation.yield(.screenCaptureUnavailable(error))
            }
            let trackURLs = try activeCaptureSession.closeWriters()
            let mixdown: RecordingMixdownOutcome

            do {
                guard createMixdown else {
                    throw RecorderError.mixdownFailed("Mixdown skipped to preserve free space. Source tracks are saved.")
                }
                let mixdownURL = try await dependencies.mixdownExporter.export(
                    systemAudioURL: trackURLs.systemAudioURL,
                    microphoneURL: trackURLs.microphoneURL,
                    destinationURL: activeCaptureSession.outputFileSet.mixdownURL
                )
                mixdown = .mixed(mixdownURL)
            } catch {
                mixdown = .failed(normalizeMixdown(error))
            }

            let result = RecordingResult(
                duration: await session.elapsed,
                systemAudioURL: trackURLs.systemAudioURL,
                microphoneURL: trackURLs.microphoneURL,
                screenCaptureURL: screenCaptureOutcome.url,
                mixdown: mixdown,
                displayFileName: activeCaptureSession.outputFileSet.displayFileName
            )
            self.activeCaptureSession = nil
            let complete = try await session.complete(with: result)
            publish(complete)
            return result
        } catch {
            self.activeCaptureSession = nil
            let recorderError = normalize(error, fallback: "Could not finish recording.")
            publish(await session.fail(with: recorderError))
            throw recorderError
        }
    }

    private func makeCaptureSession(
        sources: RecordingSources,
        microphoneInput: MicrophoneInputDeviceSelection,
        screenCaptureTarget: ScreenCaptureTarget?,
        outputDirectoryURL: URL
    ) async throws -> ActiveCaptureSession {
        let outputDirectory = dependencies.outputDirectoryFactory(outputDirectoryURL)
        let startDate = await session.startDate ?? Date()
        let outputFileSet = try outputDirectory.fileSet(for: startDate)
        var processors: [RecordingTrack: TrackProcessor] = [:]
        var systemAudioCaptures: [any AudioCapture] = []
        var microphoneCapture: (any AudioCapture)?
        var screenCapture: (any ScreenCapturing)?
        var screenCapturePreparationError: RecorderError?
        let eventHandler: @Sendable (RecorderEvent) -> Void = { [eventContinuation] event in
            eventContinuation.yield(event)
        }

        if sources.systemAudioEnabled {
            let writer = try dependencies.writerFactory(.systemAudio, outputFileSet.systemAudioURL)
            let processor = TrackProcessor(track: .systemAudio, writer: writer, eventHandler: eventHandler)
            processors[.systemAudio] = processor
            systemAudioCaptures.append(dependencies.systemAudioCaptureFactory { buffer, time in
                processor.append(buffer, time: time)
            })
        }

        if sources.microphoneEnabled {
            let writer = try dependencies.writerFactory(.microphone, outputFileSet.microphoneURL)
            let processor = TrackProcessor(track: .microphone, writer: writer, eventHandler: eventHandler)
            processors[.microphone] = processor
            microphoneCapture = dependencies.microphoneCaptureFactory(microphoneInput) { buffer, time in
                processor.append(buffer, time: time)
            }
        }

        if sources.screenCaptureEnabled {
            if let screenCaptureTarget {
                screenCapture = dependencies.screenCaptureFactory(
                    screenCaptureTarget,
                    outputFileSet.screenCaptureURL,
                    configuration.screenCaptureVideo
                )
            } else {
                screenCapturePreparationError = RecorderError.captureFailed(
                    "Choose a display, window, or application before starting screen capture."
                )
            }
        }

        return ActiveCaptureSession(
            systemAudioCaptures: systemAudioCaptures,
            microphoneCapture: microphoneCapture,
            screenCapture: screenCapture,
            screenCapturePreparationError: screenCapturePreparationError,
            processors: processors,
            outputFileSet: outputFileSet
        )
    }

    private func normalize(_ error: Error, fallback: String) -> RecorderError {
        if let recorderError = error as? RecorderError {
            return recorderError
        }

        return RecorderError.captureFailed("\(fallback) \(error.localizedDescription)")
    }

    private func normalizeMixdown(_ error: Error) -> RecorderError {
        if let recorderError = error as? RecorderError,
           case .mixdownFailed = recorderError {
            return recorderError
        }

        return RecorderError.mixdownFailed(
            "Could not create the mixdown. \(error.localizedDescription)"
        )
    }

    public func dismiss() async throws {
        let state = try await session.dismiss()
        publish(state)
    }

    private func publish(_ states: [RecorderState]) {
        states.forEach(publish)
    }

    private func publish(_ state: RecorderState) {
        eventContinuation.yield(.stateChanged(state))
    }

    private static func makeEventStream() -> (
        AsyncStream<RecorderEvent>,
        AsyncStream<RecorderEvent>.Continuation
    ) {
        var continuation: AsyncStream<RecorderEvent>.Continuation?
        let stream = AsyncStream<RecorderEvent>(bufferingPolicy: .bufferingNewest(100)) {
            continuation = $0
        }

        guard let continuation else {
            preconditionFailure("AsyncStream continuation was not created.")
        }

        return (stream, continuation)
    }
}

private final class ActiveCaptureSession {
    let outputFileSet: OutputFileSet

    private let systemAudioCaptures: [any AudioCapture]
    private let processors: [RecordingTrack: TrackProcessor]
    private var microphoneCapture: (any AudioCapture)?
    private var screenCapture: (any ScreenCapturing)?
    private let screenCapturePreparationError: RecorderError?

    init(
        systemAudioCaptures: [any AudioCapture],
        microphoneCapture: (any AudioCapture)?,
        screenCapture: (any ScreenCapturing)?,
        screenCapturePreparationError: RecorderError?,
        processors: [RecordingTrack: TrackProcessor],
        outputFileSet: OutputFileSet
    ) {
        self.systemAudioCaptures = systemAudioCaptures
        self.microphoneCapture = microphoneCapture
        self.screenCapture = screenCapture
        self.screenCapturePreparationError = screenCapturePreparationError
        self.processors = processors
        self.outputFileSet = outputFileSet
    }

    func start() async throws -> RecorderError? {
        do {
            for capture in captures {
                try await capture.start()
            }
        } catch {
            stopImmediately()
            throw error
        }

        guard let screenCapture else {
            return screenCapturePreparationError
        }

        do {
            try await screenCapture.start()
            return nil
        } catch {
            self.screenCapture = nil
            return Self.screenCaptureError(error, fallback: "Could not start screen capture.")
        }
    }

    func stopImmediately() {
        captures.forEach { $0.stop() }
    }

    func stop() async -> (url: URL?, error: RecorderError?) {
        stopImmediately()
        guard let screenCapture else {
            return (nil, nil)
        }

        do {
            return (try await screenCapture.stop(), nil)
        } catch {
            try? FileManager.default.removeItem(at: outputFileSet.screenCaptureURL)
            return (nil, Self.screenCaptureError(error, fallback: "Could not save screen capture."))
        }
    }

    func pause() {
        processors.values.forEach { $0.pause() }
        screenCapture?.pause()
    }

    func resume() {
        processors.values.forEach { $0.resume() }
        screenCapture?.resume()
    }

    func closeWriters() throws -> (systemAudioURL: URL?, microphoneURL: URL?) {
        let systemAudioURL = try processors[.systemAudio]?.close()
        let microphoneURL = try processors[.microphone]?.close()
        return (systemAudioURL, microphoneURL)
    }

    func switchMicrophoneCapture(
        makeCapture: (TrackProcessor) -> any AudioCapture
    ) async throws {
        guard let processor = processors[.microphone],
              let currentCapture = microphoneCapture else {
            throw RecorderError.microphoneNotEnabled("Microphone capture is not enabled for this recording.")
        }

        let replacementCapture = makeCapture(processor)
        try await replacementCapture.start()
        currentCapture.stop()
        microphoneCapture = replacementCapture
    }

    private var captures: [any AudioCapture] {
        systemAudioCaptures + [microphoneCapture].compactMap { $0 }
    }

    private static func screenCaptureError(_ error: Error, fallback: String) -> RecorderError {
        if let recorderError = error as? RecorderError {
            return recorderError
        }

        return RecorderError.captureFailed("\(fallback) \(error.localizedDescription)")
    }
}

private extension RecorderState {
    var allowsMicrophoneInputSwitch: Bool {
        switch self {
        case .recording, .paused:
            true
        case .idle, .preparing, .finalizing, .complete, .failed:
            false
        }
    }

    var debugName: String {
        switch self {
        case .idle:
            "idle"
        case .preparing:
            "preparing"
        case .recording:
            "recording"
        case .paused:
            "paused"
        case .finalizing:
            "finalizing"
        case .complete:
            "complete"
        case .failed:
            "failed"
        }
    }
}
