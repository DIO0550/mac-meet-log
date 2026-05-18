import Foundation

struct RecorderStateMachine: Sendable {
    private(set) var state: RecorderState = .idle

    mutating func startPreparing() throws -> RecorderState {
        guard case .idle = state else {
            throw invalidState(for: "start")
        }

        state = .preparing
        return state
    }

    mutating func markRecording(startedAt: Date) throws -> RecorderState {
        guard case .preparing = state else {
            throw invalidState(for: "prepare recording")
        }

        state = .recording(startedAt: startedAt)
        return state
    }

    mutating func pause(elapsed: Duration) throws -> RecorderState {
        guard case .recording = state else {
            throw invalidState(for: "pause")
        }

        state = .paused(elapsed: elapsed)
        return state
    }

    mutating func resume(startedAt: Date) throws -> RecorderState {
        guard case .paused = state else {
            throw invalidState(for: "resume")
        }

        state = .recording(startedAt: startedAt)
        return state
    }

    mutating func startFinalizing() throws -> RecorderState {
        switch state {
        case .recording, .paused:
            state = .finalizing
            return state
        default:
            throw invalidState(for: "stop")
        }
    }

    mutating func complete(with result: RecordingResult) throws -> RecorderState {
        guard case .finalizing = state else {
            throw invalidState(for: "complete")
        }

        state = .complete(result)
        return state
    }

    mutating func fail(with error: RecorderError) -> RecorderState {
        state = .failed(error)
        return state
    }

    mutating func dismiss() throws -> RecorderState {
        switch state {
        case .complete, .failed:
            state = .idle
            return state
        default:
            throw invalidState(for: "dismiss")
        }
    }

    private func invalidState(for operation: String) -> RecorderError {
        RecorderError.invalidState(operation: operation, state: state.debugName)
    }
}

private extension RecorderState {
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
