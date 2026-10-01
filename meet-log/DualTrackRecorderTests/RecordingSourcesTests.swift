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

    @Test func defaultScreenCaptureProfileDocumentsHourlySize() {
        let configuration = ScreenCaptureVideoConfiguration.default

        #expect(configuration.framesPerSecond == 15)
        #expect(configuration.maximumWidth == 1_920)
        #expect(configuration.maximumHeight == 1_080)
        #expect(configuration.estimatedBytesPerHour == 1_800_000_000)
    }
}
