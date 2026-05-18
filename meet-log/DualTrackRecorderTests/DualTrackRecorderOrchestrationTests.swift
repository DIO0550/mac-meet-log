import Foundation
import Testing
@testable import DualTrackRecorder

struct DualTrackRecorderOrchestrationTests {
    @Test func startStopPublishesCompleteResult() async throws {
        let harness = FakeRecorderHarness(baseURL: temporaryOutputURL())
        let recorder = DualTrackRecorder(configuration: configuration(), dependencies: harness.dependencies)
        let eventsTask = collectEvents(from: recorder.events, count: 4)

        try await recorder.start(sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: true))
        let result = try await recorder.stop()
        let events = await eventsTask.value

        #expect(harness.systemAudioCapture.startCount == 1)
        #expect(harness.microphoneCapture.startCount == 1)
        #expect(harness.systemAudioCapture.stopCount == 1)
        #expect(harness.microphoneCapture.stopCount == 1)
        #expect(result.systemAudioURL == harness.writers[.systemAudio]?.url)
        #expect(result.microphoneURL == harness.writers[.microphone]?.url)
        #expect(result.mixdownURL == harness.mixdownExporter.requestedDestinationURL)
        #expect(events.contains(.stateChanged(.preparing)))
        #expect(events.contains(.stateChanged(.finalizing)))

        guard let lastEvent = events.last,
              case let .stateChanged(.complete(completedResult)) = lastEvent else {
            Issue.record("Expected the last event to be complete.")
            return
        }

        #expect(completedResult == result)
    }

    @Test func pauseResumePausesAndResumesWriters() async throws {
        let harness = FakeRecorderHarness(baseURL: temporaryOutputURL())
        let recorder = DualTrackRecorder(configuration: configuration(), dependencies: harness.dependencies)
        let eventsTask = collectEvents(from: recorder.events, count: 6)

        try await recorder.start(sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: true))
        try await recorder.pause()
        try await recorder.resume()
        _ = try await recorder.stop()
        let events = await eventsTask.value

        #expect(harness.writers[.systemAudio]?.pauseCount == 1)
        #expect(harness.writers[.microphone]?.pauseCount == 1)
        #expect(harness.writers[.systemAudio]?.resumeCount == 1)
        #expect(harness.writers[.microphone]?.resumeCount == 1)
        #expect(events.contains { event in
            if case .stateChanged(.paused(_)) = event {
                return true
            }
            return false
        })
    }

    @Test func captureFailurePublishesFailedState() async {
        let harness = FakeRecorderHarness(baseURL: temporaryOutputURL())
        let expectedError = RecorderError.captureFailed("fake capture failed")
        harness.systemAudioCapture.startError = expectedError
        let recorder = DualTrackRecorder(configuration: configuration(), dependencies: harness.dependencies)
        let eventsTask = collectEvents(from: recorder.events, count: 3)

        do {
            try await recorder.start(sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false))
            Issue.record("Expected start to throw.")
        } catch let error as RecorderError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected RecorderError, got \(error).")
        }
        let events = await eventsTask.value

        #expect(events.last == Optional.some(.stateChanged(.failed(expectedError))))
    }

    private func configuration() -> RecorderConfiguration {
        RecorderConfiguration(outputDirectory: temporaryOutputURL())
    }

    private func temporaryOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DualTrackRecorderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func collectEvents(from stream: AsyncStream<RecorderEvent>, count: Int) -> Task<[RecorderEvent], Never> {
        Task {
            var events: [RecorderEvent] = []

            for await event in stream {
                events.append(event)

                if events.count >= count {
                    break
                }
            }

            return events
        }
    }
}
