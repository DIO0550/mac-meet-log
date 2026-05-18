import Foundation
import Testing
@testable import DualTrackRecorder

struct RecorderStateMachineTests {
    @Test func normalRecordingTransitionReachesComplete() throws {
        var stateMachine = RecorderStateMachine()
        let startedAt = Date(timeIntervalSince1970: 0)
        let result = RecordingResult(
            duration: .seconds(12),
            systemAudioURL: nil,
            microphoneURL: nil,
            mixdownURL: URL(fileURLWithPath: "/tmp/meeting.m4a"),
            displayFileName: "meeting"
        )

        #expect(try stateMachine.startPreparing() == .preparing)
        #expect(try stateMachine.markRecording(startedAt: startedAt) == .recording(startedAt: startedAt))
        #expect(try stateMachine.startFinalizing() == .finalizing)
        #expect(try stateMachine.complete(with: result) == .complete(result))
    }

    @Test func pauseAndResumeTransitionReturnsToRecording() throws {
        var stateMachine = RecorderStateMachine()
        let startedAt = Date(timeIntervalSince1970: 0)

        _ = try stateMachine.startPreparing()
        _ = try stateMachine.markRecording(startedAt: startedAt)

        #expect(try stateMachine.pause(elapsed: .seconds(3)) == .paused(elapsed: .seconds(3)))
        #expect(try stateMachine.resume(startedAt: startedAt) == .recording(startedAt: startedAt))
    }

    @Test func invalidTransitionThrowsInvalidState() {
        var stateMachine = RecorderStateMachine()

        #expect(throws: RecorderError.self) {
            try stateMachine.pause(elapsed: .zero)
        }
    }
}
