import Testing
@testable import DualTrackRecorder

struct RecordingSourcesTests {
    @Test func validationAllowsSystemAudioOnly() throws {
        let sources = RecordingSources(systemAudioEnabled: true, microphoneEnabled: false)

        try sources.validate()
    }

    @Test func validationAllowsMicrophoneOnly() throws {
        let sources = RecordingSources(systemAudioEnabled: false, microphoneEnabled: true)

        try sources.validate()
    }

    @Test func validationRejectsDisabledSources() {
        let sources = RecordingSources(systemAudioEnabled: false, microphoneEnabled: false)

        #expect(throws: RecorderError.self) {
            try sources.validate()
        }
    }
}
