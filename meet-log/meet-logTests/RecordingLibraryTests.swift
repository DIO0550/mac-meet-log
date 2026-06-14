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
        #expect(item?.mixdownStatus == .mixed)
        #expect(item?.canRemix == false)
    }

    @MainActor
    @Test func restoresFlatMixdownsAndSourceOnlyRecordingsAndSortsNewestFirst() async throws {
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

        #expect(items.map { $0.id } == [
            "2026-05-19_12-00-00",
            "2026-05-19_11-00-00",
            "2026-05-19_09-00-00"
        ])
        #expect(items[0].mixdownStatus == .needsMix)
        #expect(items[0].canRemix)
        #expect(items[0].sourceSummary == "System audio only")
        #expect(items[1].mixdownStatus == .mixed)
        #expect(items[1].sourceSummary == "Microphone only")
    }

    @MainActor
    @Test func sourceOnlyItemUsesExistingTrackCreationDateWhenStemIsNotParseable() throws {
        let directoryURL = try makeTemporaryDirectory()
        let systemURL = directoryURL.appendingPathComponent("meeting_audio_system.m4a")
        let expectedDate = Date(timeIntervalSince1970: 1_800_000_000)
        try Data().write(to: systemURL)
        try FileManager.default.setAttributes([.creationDate: expectedDate], ofItemAtPath: systemURL.path)

        let item = RecordingLibraryItem(
            stem: "meeting_audio",
            directoryURL: directoryURL,
            directoryContents: Set(["meeting_audio_system.m4a"]),
            durationProvider: FixedDurationProvider(duration: nil)
        )

        #expect(item?.createdAt == expectedDate)
        #expect(item?.mixdownStatus == .needsMix)
    }

    @MainActor
    @Test func restoresSessionFolderMixdowns() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let sessionDirectoryURL = directoryURL.appendingPathComponent("2026-05-19_13-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_mix.m4a"))
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_system.m4a"))
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_microphone.m4a"))

        let store = OutputDirectoryRecordingLibraryStore(
            outputDirectoryURL: directoryURL,
            durationProvider: FixedDurationProvider(duration: .seconds(90))
        )

        let items = try await store.recordings()

        #expect(items.map { $0.id } == ["2026-05-19_13-00-00"])
        #expect(items.first?.sessionDirectoryURL.standardizedFileURL == sessionDirectoryURL.standardizedFileURL)
        #expect(items.first?.mixdownStatus == .mixed)
        #expect(items.first?.sourceSummary == "System audio + microphone")
        #expect(items.first?.durationText == "1 min 30 sec")
    }

    @MainActor
    @Test func sessionFolderItemWinsWhenFlatItemHasSameID() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let sessionDirectoryURL = directoryURL.appendingPathComponent("2026-05-19_13-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)
        try Data().write(to: directoryURL.appendingPathComponent("2026-05-19_13-00-00_mix.m4a"))
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_mix.m4a"))
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_system.m4a"))
        try Data().write(to: sessionDirectoryURL.appendingPathComponent("2026-05-19_13-00-00_microphone.m4a"))

        let store = OutputDirectoryRecordingLibraryStore(
            outputDirectoryURL: directoryURL,
            durationProvider: FixedDurationProvider(duration: nil)
        )

        let items = try await store.recordings()

        #expect(items.count == 1)
        #expect(items.first?.sessionDirectoryURL.standardizedFileURL == sessionDirectoryURL.standardizedFileURL)
        #expect(items.first?.sourceSummary == "System audio + microphone")
    }

    @MainActor
    @Test func unreadableSessionFolderDoesNotFailLibraryLoad() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let readableDirectoryURL = directoryURL.appendingPathComponent("2026-05-19_14-00-00", isDirectory: true)
        let unreadableDirectoryURL = directoryURL.appendingPathComponent("2026-05-19_15-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: readableDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadableDirectoryURL, withIntermediateDirectories: true)
        try Data().write(to: readableDirectoryURL.appendingPathComponent("2026-05-19_14-00-00_mix.m4a"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableDirectoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectoryURL.path)
        }

        let store = OutputDirectoryRecordingLibraryStore(
            outputDirectoryURL: directoryURL,
            durationProvider: FixedDurationProvider(duration: nil)
        )

        let items = try await store.recordings()

        #expect(items.map { $0.id } == ["2026-05-19_14-00-00"])
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
    @Test func viewModelDoesNotRemixWhenLibraryLoads() async throws {
        let item = makeItem(id: "2026-05-19_12-00-00", mixdownExists: false, systemAudioExists: true)
        let mixdownService = FakeRecordingLibraryMixdownService(result: .success(item.mixdownURL))
        let viewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .summarized(makeSummary())),
            summaryStore: FakeMeetingSummaryStore(summary: nil),
            mixdownService: mixdownService
        )

        await viewModel.load()

        #expect(viewModel.selectedItem == item)
        #expect(mixdownService.exportCallCount == 0)
    }

    @MainActor
    @Test func viewModelRemixesSelectedItemAndRefreshesLibrary() async throws {
        let item = makeItem(id: "2026-05-19_12-00-00", mixdownExists: false, systemAudioExists: true)
        let mixedItem = makeItem(id: "2026-05-19_12-00-00", mixdownExists: true, systemAudioExists: true)
        let store = SequenceRecordingLibraryStore(results: [[item], [mixedItem]])
        let mixdownService = FakeRecordingLibraryMixdownService(result: .success(item.mixdownURL))
        let viewModel = LibraryViewModel(
            store: store,
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .summarized(makeSummary())),
            summaryStore: FakeMeetingSummaryStore(summary: nil),
            mixdownService: mixdownService
        )

        await viewModel.load()
        viewModel.remixSelectedItem()
        try await waitUntil { mixdownService.exportCallCount == 1 && viewModel.selectedItem == mixedItem }

        #expect(mixdownService.requestedSystemAudioURL == item.systemAudioURL)
        #expect(mixdownService.requestedMicrophoneURL == nil)
        #expect(mixdownService.requestedDestinationURL == item.mixdownURL)
        #expect(store.recordingsCallCount == 2)
        #expect(viewModel.remixState == .idle)
    }

    @MainActor
    @Test func viewModelKeepsItemAndReportsFailureWhenRemixFails() async throws {
        let item = makeItem(id: "2026-05-19_12-00-00", mixdownExists: false, systemAudioExists: true)
        let expectedError = RecordingLibraryMixdownTestError.failed
        let mixdownService = FakeRecordingLibraryMixdownService(result: .failure(expectedError))
        let viewModel = LibraryViewModel(
            store: FakeRecordingLibraryStore(items: [item]),
            transcriptionService: FakeAudioTranscriptionService(result: .success(makeTranscript())),
            summaryService: FakeTranscriptSummaryService(result: .summarized(makeSummary())),
            summaryStore: FakeMeetingSummaryStore(summary: nil),
            mixdownService: mixdownService
        )

        await viewModel.load()
        viewModel.remixSelectedItem()
        try await waitUntil {
            if case let .failed(id, message) = viewModel.remixState {
                return id == item.id && message == expectedError.localizedDescription
            }

            return false
        }

        #expect(viewModel.selectedItem == item)
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

    private func makeItem(
        id: String,
        mixdownExists: Bool = true,
        systemAudioExists: Bool = false,
        microphoneExists: Bool = false
    ) -> RecordingLibraryItem {
        let directoryURL = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        let systemAudioURL = systemAudioExists ? directoryURL.appendingPathComponent("\(id)_system.m4a") : nil
        let microphoneURL = microphoneExists ? directoryURL.appendingPathComponent("\(id)_microphone.m4a") : nil

        return RecordingLibraryItem(
            id: id,
            title: id,
            createdAt: Date(timeIntervalSince1970: 0),
            duration: .seconds(60),
            mixdownURL: directoryURL.appendingPathComponent("\(id)_mix.m4a"),
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            fileExistence: RecordingLibraryFileExistence(
                mixdownExists: mixdownExists,
                systemAudioExists: systemAudioExists,
                microphoneExists: microphoneExists
            ),
            sessionDirectoryURL: directoryURL,
            mixdownStatus: mixdownExists ? .mixed : (systemAudioExists || microphoneExists ? .needsMix : .unavailable)
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

private enum RecordingLibraryMixdownTestError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "Mix failed"
    }
}

private final class FakeRecordingLibraryMixdownService: RecordingLibraryMixdownServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<URL, Error>
    private var exportCallCountValue = 0
    private var requestedSystemAudioURLValue: URL?
    private var requestedMicrophoneURLValue: URL?
    private var requestedDestinationURLValue: URL?

    init(result: Result<URL, Error>) {
        self.result = result
    }

    var exportCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exportCallCountValue
    }

    var requestedSystemAudioURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedSystemAudioURLValue
    }

    var requestedMicrophoneURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedMicrophoneURLValue
    }

    var requestedDestinationURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedDestinationURLValue
    }

    func export(systemAudioURL: URL?, microphoneURL: URL?, destinationURL: URL) async throws -> URL {
        lock.lock()
        exportCallCountValue += 1
        requestedSystemAudioURLValue = systemAudioURL
        requestedMicrophoneURLValue = microphoneURL
        requestedDestinationURLValue = destinationURL
        lock.unlock()

        return try result.get()
    }
}

private final class SequenceRecordingLibraryStore: RecordingLibraryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[RecordingLibraryItem]]
    private var recordingsCallCountValue = 0

    init(results: [[RecordingLibraryItem]]) {
        self.results = results
    }

    var recordingsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordingsCallCountValue
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        lock.lock()
        defer { lock.unlock() }
        recordingsCallCountValue += 1

        guard results.count > 1 else {
            return results.first ?? []
        }

        return results.removeFirst()
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
