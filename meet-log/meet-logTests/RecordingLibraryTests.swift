import Foundation
import Testing
@testable import meet_log

struct RecordingLibraryTests {
    @MainActor
    @Test func restoresItemFromMixdownAndOptionalTracks() throws {
        let directoryURL = try makeTemporaryDirectory()
        let mixdownURL = directoryURL.appendingPathComponent("2026-05-19_10-30-00_mix.m4a")
        let systemURL = directoryURL.appendingPathComponent("2026-05-19_10-30-00_system.m4a")
        try Data().write(to: mixdownURL)
        try Data().write(to: systemURL)

        let item = RecordingLibraryItem(
            mixdownURL: mixdownURL,
            directoryContents: Set(["2026-05-19_10-30-00_mix.m4a", "2026-05-19_10-30-00_system.m4a"]),
            durationProvider: FixedDurationProvider(duration: .seconds(125))
        )

        #expect(item?.id == "2026-05-19_10-30-00")
        #expect(item?.durationText == "2 min 05 sec")
        #expect(item?.sourceSummary == "System audio only")
        #expect(item?.mixdownURL == mixdownURL)
        #expect(item?.systemAudioURL == systemURL)
        #expect(item?.microphoneURL == nil)
    }

    @MainActor
    @Test func ignoresNonMixdownFilesAndSortsNewestFirst() async throws {
        let directoryURL = try makeTemporaryDirectory()
        try Data().write(to: directoryURL.appendingPathComponent("2026-05-19_09-00-00_mix.m4a"))
        try Data().write(to: directoryURL.appendingPathComponent("2026-05-19_11-00-00_mix.m4a"))
        try Data().write(to: directoryURL.appendingPathComponent("2026-05-19_11-00-00_microphone.m4a"))
        try Data().write(to: directoryURL.appendingPathComponent("2026-05-19_12-00-00_system.m4a"))

        let store = OutputDirectoryRecordingLibraryStore(
            outputDirectoryURL: directoryURL,
            durationProvider: FixedDurationProvider(duration: nil)
        )

        let items = try await store.recordings()

        #expect(items.map { $0.id } == ["2026-05-19_11-00-00", "2026-05-19_09-00-00"])
        #expect(items.first?.sourceSummary == "Microphone only")
    }

    @MainActor
    @Test func missingDirectoryReturnsEmptyLibrary() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = OutputDirectoryRecordingLibraryStore(outputDirectoryURL: directoryURL)

        let items = try await store.recordings()

        #expect(items.isEmpty)
    }

    @MainActor
    @Test func viewModelLoadsEmptyAndLoadedStates() async throws {
        let item = makeItem(id: "2026-05-19_10-30-00")
        let emptyViewModel = LibraryViewModel(store: FakeRecordingLibraryStore(items: []))
        await emptyViewModel.load()

        #expect(emptyViewModel.state == .empty)
        #expect(emptyViewModel.selectedItem == nil)

        let loadedViewModel = LibraryViewModel(store: FakeRecordingLibraryStore(items: [item]))
        await loadedViewModel.load()

        #expect(loadedViewModel.state == .loaded([item]))
        #expect(loadedViewModel.selectedItem == item)
    }

    @MainActor
    @Test func viewModelSelectionSurvivesRefreshWhenItemStillExists() async throws {
        let older = makeItem(id: "2026-05-19_09-00-00")
        let newer = makeItem(id: "2026-05-19_11-00-00")
        let viewModel = LibraryViewModel(store: FakeRecordingLibraryStore(items: [newer, older]))
        await viewModel.load()

        viewModel.select(older)
        viewModel.refresh()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.selectedItem == older)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingLibraryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(id: String) -> RecordingLibraryItem {
        RecordingLibraryItem(
            id: id,
            title: id,
            createdAt: Date(timeIntervalSince1970: 0),
            duration: .seconds(60),
            mixdownURL: URL(fileURLWithPath: "/tmp/\(id)_mix.m4a"),
            systemAudioURL: nil,
            microphoneURL: nil,
            fileExistence: RecordingLibraryFileExistence(
                mixdownExists: true,
                systemAudioExists: false,
                microphoneExists: false
            )
        )
    }
}

private struct FixedDurationProvider: RecordingDurationProviding {
    let duration: Duration?

    func duration(for url: URL) -> Duration? {
        duration
    }
}
