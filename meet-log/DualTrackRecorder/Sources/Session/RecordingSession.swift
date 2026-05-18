import Foundation

actor RecordingSession {
    private var stateMachine = RecorderStateMachine()
    private var clock: RecordingClock
    private var activeSources: RecordingSources?
    private var startedAt: Date?

    init(clock: RecordingClock = RecordingClock()) {
        self.clock = clock
    }

    var state: RecorderState {
        stateMachine.state
    }

    var elapsed: Duration {
        clock.elapsed
    }

    var startDate: Date? {
        startedAt
    }

    func start(sources: RecordingSources) throws -> [RecorderState] {
        try sources.validate()

        let preparing = try stateMachine.startPreparing()
        clock.start()

        guard let startTime = clock.startedAt else {
            let error = RecorderError.invalidState(operation: "start clock", state: "idle")
            _ = stateMachine.fail(with: error)
            throw error
        }

        activeSources = sources
        startedAt = startTime

        do {
            let recording = try stateMachine.markRecording(startedAt: startTime)
            return [preparing, recording]
        } catch let error as RecorderError {
            _ = stateMachine.fail(with: error)
            throw error
        }
    }

    func pause() throws -> RecorderState {
        let elapsed = try clock.pause()
        return try stateMachine.pause(elapsed: elapsed)
    }

    func resume() throws -> RecorderState {
        try clock.resume()

        guard let startedAt else {
            throw RecorderError.invalidState(operation: "resume", state: "idle")
        }

        return try stateMachine.resume(startedAt: startedAt)
    }

    func startFinalizing() throws -> RecorderState {
        try stateMachine.startFinalizing()
    }

    func complete(with result: RecordingResult) throws -> RecorderState {
        let complete = try stateMachine.complete(with: result)

        activeSources = nil
        startedAt = nil

        return complete
    }

    func fail(with error: RecorderError) -> RecorderState {
        activeSources = nil
        startedAt = nil
        return stateMachine.fail(with: error)
    }

    func dismiss() throws -> RecorderState {
        try stateMachine.dismiss()
    }
}
