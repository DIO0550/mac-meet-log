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

    public func start(sources: RecordingSources) async throws {
        let states = try await session.start(sources: sources)
        publish(states)

        do {
            activeCaptureSession = try await makeCaptureSession(sources: sources)
            try await activeCaptureSession?.start()
        } catch {
            activeCaptureSession?.stop()
            activeCaptureSession = nil
            let recorderError = normalize(error, fallback: "Could not start recording.")
            publish(await session.fail(with: recorderError))
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

    public func stop() async throws -> RecordingResult {
        let finalizing = try await session.startFinalizing()
        publish(finalizing)

        guard let activeCaptureSession else {
            let error = RecorderError.invalidState(operation: "stop capture", state: "idle")
            publish(await session.fail(with: error))
            throw error
        }

        do {
            activeCaptureSession.stop()
            let trackURLs = try activeCaptureSession.closeWriters()
            let mixdownURL = try await dependencies.mixdownExporter.export(
                systemAudioURL: trackURLs.systemAudioURL,
                microphoneURL: trackURLs.microphoneURL,
                destinationURL: activeCaptureSession.outputFileSet.mixdownURL
            )
            let result = RecordingResult(
                duration: await session.elapsed,
                systemAudioURL: trackURLs.systemAudioURL,
                microphoneURL: trackURLs.microphoneURL,
                mixdownURL: mixdownURL,
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

    private func makeCaptureSession(sources: RecordingSources) async throws -> ActiveCaptureSession {
        let outputDirectory = dependencies.outputDirectoryFactory(configuration.outputDirectory)
        let startDate = await session.startDate ?? Date()
        let outputFileSet = try outputDirectory.fileSet(for: startDate)
        var processors: [RecordingTrack: TrackProcessor] = [:]
        var captures: [any AudioCapture] = []
        let eventHandler: @Sendable (RecorderEvent) -> Void = { [eventContinuation] event in
            eventContinuation.yield(event)
        }

        if sources.systemAudioEnabled {
            let writer = try dependencies.writerFactory(.systemAudio, outputFileSet.systemAudioURL)
            let processor = TrackProcessor(track: .systemAudio, writer: writer, eventHandler: eventHandler)
            processors[.systemAudio] = processor
            captures.append(dependencies.systemAudioCaptureFactory { buffer, time in
                processor.append(buffer, time: time)
            })
        }

        if sources.microphoneEnabled {
            let writer = try dependencies.writerFactory(.microphone, outputFileSet.microphoneURL)
            let processor = TrackProcessor(track: .microphone, writer: writer, eventHandler: eventHandler)
            processors[.microphone] = processor
            captures.append(dependencies.microphoneCaptureFactory { buffer, time in
                processor.append(buffer, time: time)
            })
        }

        return ActiveCaptureSession(
            captures: captures,
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

    private let captures: [any AudioCapture]
    private let processors: [RecordingTrack: TrackProcessor]

    init(
        captures: [any AudioCapture],
        processors: [RecordingTrack: TrackProcessor],
        outputFileSet: OutputFileSet
    ) {
        self.captures = captures
        self.processors = processors
        self.outputFileSet = outputFileSet
    }

    func start() async throws {
        do {
            for capture in captures {
                try await capture.start()
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        captures.forEach { $0.stop() }
    }

    func pause() {
        processors.values.forEach { $0.pause() }
    }

    func resume() {
        processors.values.forEach { $0.resume() }
    }

    func closeWriters() throws -> (systemAudioURL: URL?, microphoneURL: URL?) {
        let systemAudioURL = try processors[.systemAudio]?.close()
        let microphoneURL = try processors[.microphone]?.close()
        return (systemAudioURL, microphoneURL)
    }
}
