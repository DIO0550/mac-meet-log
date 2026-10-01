import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct AppSettingsTests {
    @Test func untouchedSettingsPreserveExistingBehavior() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.preferences == AppPreferences())
        #expect(settings.preferences.systemAudioEnabled)
        #expect(settings.preferences.microphoneEnabled)
        #expect(settings.preferences.localeIdentifier == "ja-JP")
        #expect(settings.preferences.summaryTemplateID == "meeting")
        #expect(try settings.resolveOutputDirectory() == RecordingStorage.defaultOutputDirectoryURL)
    }

    @Test func preferencesSurviveRecreationAndDeviceIDChanges() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        first.preferences.systemAudioEnabled = false
        first.preferences.microphoneEnabled = false
        first.preferences.localeIdentifier = "en-US"
        first.preferences.microphoneDeviceUID = "stable-uid"
        let restored = AppSettings(defaults: defaults)
        #expect(restored.preferences == first.preferences)
        let reconnected = AudioInputDevice(id: "99", name: "USB", persistentUID: "stable-uid")
        #expect(restored.defaultMicrophoneID(in: [reconnected]) == "99")
        #expect(restored.defaultMicrophoneID(in: []) == nil)
    }

    @Test func summaryTemplatesRoundTripAndBuiltInCannotBeDeleted() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let custom = SummaryTemplate(
            name: "1on1",
            instructions: "本人の課題と支援事項を整理してください。",
            outputPerspective: "- 要約: 状況\n- アクションアイテム: 次の一歩"
        )
        try settings.saveSummaryTemplate(custom)
        settings.preferences.summaryTemplateID = custom.id

        let restored = AppSettings(defaults: defaults)
        #expect(restored.summaryTemplate().id == custom.id)
        #expect(restored.summaryTemplates.contains(custom))
        #expect(throws: SummaryTemplateError.builtInCannotBeDeleted) {
            try restored.deleteSummaryTemplate(id: SummaryTemplate.builtIn.id)
        }
    }

    @Test func invalidSummaryTemplateIsRejected() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let invalid = SummaryTemplate(name: "", instructions: "", outputPerspective: "")

        #expect(throws: SummaryTemplateError.invalid) {
            try settings.saveSummaryTemplate(invalid)
        }
    }

    @Test func corruptPreferencesFallBackButCorruptBookmarkDoesNotSilentlyRedirectRecording() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: AppSettings.preferencesKey)
        defaults.set(Data("invalid".utf8), forKey: AppSettings.directoryBookmarkKey)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.preferences == AppPreferences())
        #expect(throws: (any Error).self) { try settings.resolveOutputDirectory() }
        settings.resetOutputDirectory()
        #expect(try settings.resolveOutputDirectory() == RecordingStorage.defaultOutputDirectoryURL)
    }

    @Test func bookmarkRoundTripAndLibraryFollowCurrentDirectoryWithoutMovingFiles() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("old", isDirectory: true)
        let new = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = old.appendingPathComponent("2026-10-01_10-00-00_microphone.m4a")
        try Data().write(to: original)
        let settings = AppSettings(defaults: defaults)
        let store = SettingsRecordingLibraryStore(settings: settings)
        try settings.selectOutputDirectory(old)
        #expect(try await store.recordings().count == 1)
        try settings.selectOutputDirectory(new)
        #expect(try await store.recordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
        let restored = AppSettings(defaults: defaults)
        #expect(try restored.resolveOutputDirectory().resolvingSymlinksInPath() == new.resolvingSymlinksInPath())
    }

    @Test func nonDirectorySelectionKeepsPreviousSetting() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = AppSettings(defaults: defaults)
        #expect(throws: (any Error).self) { try settings.selectOutputDirectory(file) }
        #expect(try settings.resolveOutputDirectory() == RecordingStorage.defaultOutputDirectoryURL)
    }

    @Test func recordingDefaultsWaitUntilRecordingEndsAndIgnoreLocaleOnlyChanges() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.preferences.microphoneDeviceUID = "usb-uid"
        let device = AudioInputDevice(id: "42", name: "USB", persistentUID: "usb-uid")
        let (events, continuation) = AsyncStream<RecorderEvent>.makeStream()
        defer { continuation.finish() }
        let result = RecordingResult(duration: .zero, systemAudioURL: nil, microphoneURL: nil,
                                     mixdown: .mixed(URL(fileURLWithPath: "/tmp/test_mix.m4a")), displayFileName: "test")
        let client = RecorderClient(events: events, microphoneDevices: { [device] }, start: { _, _ in },
                                    pause: {}, resume: {}, stop: { result }, dismiss: {},
                                    switchMicrophoneInput: { _ in })
        let model = RecorderViewModel(recorder: client, settings: settings)
        try await waitUntil { model.selectedMicrophoneDeviceID == "42" }
        model.setSystemAudioEnabled(false)
        settings.preferences.localeIdentifier = "en-US"
        #expect(!model.sources.systemAudioEnabled)
        continuation.yield(.stateChanged(.recording(startedAt: Date())))
        try await waitUntil { model.isRecording }
        settings.preferences.microphoneEnabled = false
        #expect(model.sources.microphoneEnabled)
        continuation.yield(.stateChanged(.complete(result)))
        try await waitUntil { model.completion != nil }
        #expect(!model.sources.microphoneEnabled)
        #expect(model.sources.systemAudioEnabled)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Recorder did not reach the expected state")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }
}
