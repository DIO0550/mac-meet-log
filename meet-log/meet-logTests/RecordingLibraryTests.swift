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

    @MainActor
    @Test func viewModelLoadsSavedSummaryForSelectedItem() async throws {
        let item = makeItem(id: "2026-05-19_10-30-00")
        let summary = makeSummary()
        let summaryStore = FakeMeetingSummaryStore(summary: summary)
        let viewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .summarized(summary)),
            summaryStore: summaryStore
        )

        await viewModel.load()
        try await waitUntil { viewModel.summaryState == .summarized(summary) }

        #expect(viewModel.summaryState == .summarized(summary))
    }

    @MainActor
    @Test func viewModelGeneratesSummaryAndSavesSidecar() async throws {
        let item = makeItem(id: "2026-05-19_10-30-00")
        let summary = makeSummary()
        let summaryStore = FakeMeetingSummaryStore(summary: nil)
        let viewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .summarized(summary)),
            summaryStore: summaryStore
        )

        await viewModel.load()
        viewModel.generateSummaryForSelectedItem()
        try await waitUntil { viewModel.summaryState == .summarized(summary) }

        #expect(viewModel.summaryState == .summarized(summary))
        #expect(summaryStore.savedSummary == summary)
        #expect(summaryStore.savedTranscript == makeTranscript())
        #expect(summaryStore.savedItem == item)
    }

    @MainActor
    @Test func viewModelMapsTranscriptionFailureToSummaryFailure() async throws {
        let item = makeItem(id: "2026-05-19_10-30-00")
        let viewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .failure(TranscriptionError.emptyResult)),
            summaryService: FakeTranscriptSummaryService(result: .summarized(makeSummary())),
            summaryStore: FakeMeetingSummaryStore(summary: nil)
        )

        await viewModel.load()
        viewModel.generateSummaryForSelectedItem()
        try await waitUntil {
            if case .failed = viewModel.summaryState {
                return true
            }

            return false
        }

        #expect(viewModel.summaryState == .failed(TranscriptionError.emptyResult.localizedDescription))
    }

    @MainActor
    @Test func viewModelMapsSummaryUnavailableAndFailedResults() async throws {
        let item = makeItem(id: "2026-05-19_10-30-00")
        let unavailableViewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady)),
            summaryStore: FakeMeetingSummaryStore(summary: nil)
        )
        let failedViewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .failed(.invalidStructuredOutput)),
            summaryStore: FakeMeetingSummaryStore(summary: nil)
        )

        await unavailableViewModel.load()
        unavailableViewModel.generateSummaryForSelectedItem()
        try await waitUntil {
            if case .unavailable = unavailableViewModel.summaryState {
                return true
            }

            return false
        }

        await failedViewModel.load()
        failedViewModel.generateSummaryForSelectedItem()
        try await waitUntil {
            if case .failed = failedViewModel.summaryState {
                return true
            }

            return false
        }

        #expect(unavailableViewModel.summaryState == .unavailable(SummaryUnavailableReason.modelNotReady.localizedDescription))
        #expect(failedViewModel.summaryState == .failed(SummaryError.invalidStructuredOutput.localizedDescription))
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

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting for condition.")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

private func makeTranscript() -> TranscriptResult {
    TranscriptResult(
        text: "今日は要約機能について確認しました。",
        localeIdentifier: "ja-JP",
        sourceURL: URL(fileURLWithPath: "/tmp/2026-05-19_10-30-00_mix.m4a")
    )
}

private func makeSummary() -> MeetingSummary {
    MeetingSummary(
        summary: "要約機能について確認した。",
        topics: [MeetingTopic(title: "要約", detail: "Foundation Models を使う")],
        actionItems: [MeetingActionItem(title: "実装する", owner: "DIO", dueDateText: nil)],
        transcriptSourceURL: URL(fileURLWithPath: "/tmp/2026-05-19_10-30-00_mix.m4a"),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

private struct FakeAudioTranscriptionService: AudioTranscriptionService {
    let result: Result<TranscriptResult, Error>

    func transcribe(
        audioURL: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            switch result {
            case let .success(transcript):
                continuation.yield(.completed(transcript))
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }
}

private struct FakeTranscriptSummaryService: TranscriptSummaryService {
    let result: TranscriptSummaryResult

    func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        result
    }
}

private final class FakeMeetingSummaryStore: MeetingSummaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var summaryValue: MeetingSummary?
    private var savedSummaryValue: MeetingSummary?
    private var savedTranscriptValue: TranscriptResult?
    private var savedItemValue: RecordingLibraryItem?

    init(summary: MeetingSummary?) {
        summaryValue = summary
    }

    var savedSummary: MeetingSummary? {
        lock.lock()
        defer { lock.unlock() }
        return savedSummaryValue
    }

    var savedItem: RecordingLibraryItem? {
        lock.lock()
        defer { lock.unlock() }
        return savedItemValue
    }

    var savedTranscript: TranscriptResult? {
        lock.lock()
        defer { lock.unlock() }
        return savedTranscriptValue
    }

    func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        lock.lock()
        defer { lock.unlock() }
        return summaryValue
    }

    func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {
        lock.lock()
        summaryValue = summary
        savedSummaryValue = summary
        savedItemValue = item
        lock.unlock()
    }

    func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {
        lock.lock()
        savedTranscriptValue = transcript
        savedItemValue = item
        lock.unlock()
    }
}
