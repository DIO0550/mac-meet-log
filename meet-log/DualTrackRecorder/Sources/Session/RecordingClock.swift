import Foundation

protocol TimeProviding: Sendable {
    var now: Date { get }
}

struct SystemTimeProvider: TimeProviding {
    var now: Date {
        Date()
    }
}

struct RecordingClock: Sendable {
    private let timeProvider: any TimeProviding
    private var startTime: Date?
    private var pauseTime: Date?
    private var accumulatedPausedSeconds: TimeInterval = 0

    init(timeProvider: any TimeProviding = SystemTimeProvider()) {
        self.timeProvider = timeProvider
    }

    var startedAt: Date? {
        startTime
    }

    mutating func start() {
        startTime = timeProvider.now
        pauseTime = nil
        accumulatedPausedSeconds = 0
    }

    mutating func pause() throws -> Duration {
        guard startTime != nil else {
            throw RecorderError.invalidState(operation: "pause clock", state: "idle")
        }

        guard pauseTime == nil else {
            return elapsed
        }

        pauseTime = timeProvider.now
        return elapsed
    }

    mutating func resume() throws {
        guard startTime != nil else {
            throw RecorderError.invalidState(operation: "resume clock", state: "idle")
        }

        guard let pauseTime else {
            return
        }

        accumulatedPausedSeconds += timeProvider.now.timeIntervalSince(pauseTime)
        self.pauseTime = nil
    }

    var elapsed: Duration {
        guard let startTime else {
            return .zero
        }

        let effectiveNow = pauseTime ?? timeProvider.now
        let elapsedSeconds = effectiveNow.timeIntervalSince(startTime) - accumulatedPausedSeconds
        return .timeInterval(elapsedSeconds)
    }
}

private extension Duration {
    static func timeInterval(_ seconds: TimeInterval) -> Duration {
        let clampedSeconds = max(seconds, 0)
        let wholeSeconds = Int64(clampedSeconds.rounded(.down))
        let fractionalSeconds = clampedSeconds - TimeInterval(wholeSeconds)
        let nanoseconds = Int64((fractionalSeconds * 1_000_000_000).rounded())

        return .seconds(wholeSeconds) + .nanoseconds(nanoseconds)
    }
}
