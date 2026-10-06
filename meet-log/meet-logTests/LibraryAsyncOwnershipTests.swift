import Foundation
import Testing
@testable import meet_log

@MainActor
struct LibraryAsyncOwnershipTests {
    @Test(arguments: [false, true], [false, true])
    func delayedReadCannotReplaceAnotherRecording(summaryRead: Bool, failing: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let gate = SuspensionGate()
        await fixture.storage.holdNextRead(summary: summaryRead, gate: gate, failing: failing)
        let model = fixture.model()
        let firstLoad = Task { await model.load() }
        try await waitFor { await gate.isWaiting }

        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        expectB(model, fixture: fixture)
        await gate.release()
        await firstLoad.value

        #expect(await fixture.storage.cancelledReads == 1)
        expectB(model, fixture: fixture)
    }

    @Test(arguments: [false, true], [false, true])
    func returningToSameRecordingRejectsEarlierReadGeneration(summaryRead: Bool, failing: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let gate = SuspensionGate()
        await fixture.storage.holdNextRead(summary: summaryRead, gate: gate, failing: failing)
        let model = fixture.model()
        let firstLoad = Task { await model.load() }
        try await waitFor { await gate.isWaiting }

        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        let updated = fixture.transcript(fixture.a, text: "updated A")
        let updatedSummary = fixture.summary(fixture.a, text: "updated summary A")
        await fixture.storage.seed(updated, summary: updatedSummary, for: fixture.a)
        model.select(fixture.a)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        await gate.release()
        await firstLoad.value

        #expect(model.transcript == updated)
        #expect(model.savedSummary == updatedSummary)
        #expect(model.summaryState == .summarized(updatedSummary))
        #expect(model.exportDocumentForSelectedItem()?.transcript == updated)
    }

    @Test(arguments: [false, true])
    func refreshInvalidatesReadBeforeEnumerationCompletes(failing: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let readGate = SuspensionGate()
        await fixture.storage.holdNextRead(summary: false, gate: readGate, failing: failing)
        let model = fixture.model()
        let firstLoad = Task { await model.load() }
        try await waitFor { await readGate.isWaiting }
        let refreshGate = SuspensionGate()
        await fixture.library.holdNextRead(refreshGate)
        model.refresh()
        try await waitFor { await refreshGate.isWaiting }
        #expect(model.isSummaryBusy)
        #expect(model.exportDocumentForSelectedItem()?.transcript == nil)

        await readGate.release()
        await firstLoad.value
        #expect(model.isSummaryBusy)
        #expect(model.transcript == nil)
        #expect(model.savedSummary == nil)

        await refreshGate.release()
        try await waitFor { @MainActor in !model.isSummaryBusy }
        #expect(model.transcript == fixture.transcript(fixture.a))
        #expect(model.savedSummary == fixture.summary(fixture.a))
    }

    @Test(arguments: [false, true])
    func olderLibraryEnumerationCannotRestorePreviousDestination(failing: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let gate = SuspensionGate()
        await fixture.library.holdNextRead(gate, failing: failing)
        let model = fixture.model()
        let firstLoad = Task { await model.load() }
        try await waitFor { await gate.isWaiting }
        await fixture.library.setItems([fixture.b])
        await model.load()
        expectB(model, fixture: fixture)

        await gate.release()
        await firstLoad.value
        #expect(model.items == [fixture.b])
        expectB(model, fixture: fixture)
    }

    @Test func concurrentGenerationSavesEachRecordingWithoutReplacingSelectedResult() async throws {
        let fixture = Fixture()
        await fixture.seed()
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.services.holdNextSummary(gate)
        model.runProcessing(.summary)
        try await waitFor { await gate.isWaiting }

        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        model.runProcessing(.summary)
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.b.mixdownURL) }
        let selectedSummary = try #require(model.savedSummary)
        #expect(selectedSummary.summary == "generated B")
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        #expect(model.savedSummary == selectedSummary)
        #expect(model.summaryState == .summarized(selectedSummary))
        #expect(model.transcript == fixture.transcript(fixture.b))
        #expect(model.screenOCRWarning == nil)
        #expect(model.processingConfirmation == nil)
        let document = try #require(model.exportDocumentForSelectedItem())
        #expect(document.title == "meeting B")
        #expect(document.summary == selectedSummary)
        #expect(document.transcript == fixture.transcript(fixture.b))
        #expect(await fixture.storage.savedSummaries.map(\.item.mixdownURL) == [fixture.b.mixdownURL, fixture.a.mixdownURL])
        #expect(try await fixture.storage.summary(for: fixture.a)?.summary == "generated A")
        model.select(fixture.a)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        #expect(model.savedSummary?.summary == "generated A")
    }

    @Test(arguments: [TranscriptSummaryResult.failed(.invalidStructuredOutput), .unavailable(.modelNotReady)])
    func lateFailureAndUnavailableResultStayWithTheirRecording(result: TranscriptSummaryResult) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.services.holdNextSummary(gate, result: result)
        model.runProcessing(.summary)
        try await waitFor { await gate.isWaiting }
        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        expectB(model, fixture: fixture)
        #expect(await fixture.storage.savedSummaries.isEmpty)
    }

    @Test(arguments: [false, true])
    func refreshAndDestinationChangeRejectCancelledGenerationAndLateProgress(changeDestination: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.services.holdNextSummary(gate, result: .failed(.invalidStructuredOutput))
        model.runProcessing(.summary)
        try await waitFor { await gate.isWaiting }

        // Same ID at a different path must not reuse a cached result or execution.
        let destination = Fixture.item("A", directory: fixture.directory.appendingPathComponent("new"))
        if changeDestination {
            await fixture.storage.seed(fixture.transcript(destination, text: "new destination"),
                                       summary: fixture.summary(destination, text: "new destination summary"), for: destination)
            await fixture.library.setItems([destination])
        }
        model.refresh()
        try await waitFor { @MainActor in !model.isSummaryBusy }
        let selectedTranscript = model.transcript
        let selectedSummary = try #require(model.savedSummary)
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        #expect(model.transcript == selectedTranscript)
        #expect(model.savedSummary == selectedSummary)
        #expect(model.summaryState == .summarized(selectedSummary))
        #expect(model.screenOCRWarning == nil)
        #expect(model.processingConfirmation == nil)
        #expect(await fixture.storage.savedSummaries.isEmpty)
        if changeDestination {
            #expect(model.selectedItem?.mixdownURL == destination.mixdownURL)
            #expect(model.exportDocumentForSelectedItem()?.transcript?.text == "new destination")
        }
    }

    @Test func saveAlreadyInFlightKeepsCapturedRecordingDestination() async throws {
        let fixture = Fixture()
        await fixture.seed()
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.storage.holdNextSummarySave(gate)
        model.runProcessing(.summary)
        try await waitFor { await gate.isWaiting }
        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        expectB(model, fixture: fixture)
        #expect(await fixture.storage.savedSummaries.map(\.item.mixdownURL) == [fixture.a.mixdownURL])
        #expect(try await fixture.storage.summary(for: fixture.a)?.summary == "generated A")
    }

    @Test(arguments: [false, true])
    func lateOCRWarningDoesNotAppearInAnotherRecording(refresh: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.services.holdNextOCR(gate)
        model.runProcessing(.all)
        try await waitFor { await gate.isWaiting }
        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        if refresh {
            model.refresh()
            try await waitFor { @MainActor in !model.isSummaryBusy }
        }
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        expectB(model, fixture: fixture)
        model.select(fixture.a)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        #expect(model.transcript?.screenSegments == fixture.transcript(fixture.a).screenSegments)
    }

    @Test(arguments: [false, true])
    func delayedOverwriteConfirmationCannotAttachToAnotherRecording(refresh: Bool) async throws {
        let fixture = Fixture()
        await fixture.seed()
        let edited = TranscriptResult(text: "manually edited", localeIdentifier: "ja-JP",
                                      sourceURL: fixture.a.mixdownURL, audioEditedAt: .now)
        await fixture.storage.seed(edited, summary: fixture.summary(fixture.a), for: fixture.a)
        let model = fixture.model()
        await model.load()
        let gate = SuspensionGate()
        await fixture.storage.holdNextRead(summary: false, gate: gate, failing: false)
        model.runProcessing(.all)
        try await waitFor { await gate.isWaiting }
        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        if refresh {
            model.refresh()
            try await waitFor { @MainActor in !model.isSummaryBusy }
        }
        await gate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.a.mixdownURL) }

        expectB(model, fixture: fixture)
        #expect(await fixture.storage.savedSummaries.isEmpty)
        #expect(try await fixture.storage.transcript(for: fixture.a) == edited)
    }

    private func expectB(_ model: LibraryViewModel, fixture: Fixture) {
        #expect(model.selectedItem == fixture.b)
        #expect(model.transcript == fixture.transcript(fixture.b))
        #expect(model.savedSummary == fixture.summary(fixture.b))
        #expect(model.summaryState == .summarized(fixture.summary(fixture.b)))
        #expect(model.screenOCRWarning == nil)
        #expect(model.processingConfirmation == nil)
        #expect(model.exportDocumentForSelectedItem()?.title == "meeting B")
        #expect(model.exportDocumentForSelectedItem()?.transcript == fixture.transcript(fixture.b))
        #expect(model.exportDocumentForSelectedItem()?.summary == fixture.summary(fixture.b))
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw WaitError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum WaitError: Error { case timeout }

@MainActor
private struct Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = ControlledSummaryStore()
    let services = ControlledProcessingServices()
    let library = ControlledLibraryStore()
    var a: RecordingLibraryItem { Self.item("A", directory: directory) }
    var b: RecordingLibraryItem { Self.item("B", directory: directory) }

    func seed() async {
        await library.setItems([a, b])
        await storage.seed(transcript(a), summary: summary(a), for: a)
        await storage.seed(transcript(b), summary: summary(b), for: b)
    }

    func model() -> LibraryViewModel {
        LibraryViewModel(store: library, transcriptionService: services, summaryService: services,
                         summaryStore: storage, screenOCRService: services)
    }

    func transcript(_ item: RecordingLibraryItem, text: String? = nil) -> TranscriptResult {
        TranscriptResult(text: text ?? item.id, localeIdentifier: "ja-JP", sourceURL: item.mixdownURL,
                         screenSegments: [ScreenTranscriptSegment(text: "screen \(item.id)", timestamp: 0, duration: 1)])
    }

    func summary(_ item: RecordingLibraryItem, text: String? = nil) -> MeetingSummary {
        MeetingSummary(summary: text ?? "summary \(item.id)", topics: [], actionItems: [],
                       transcriptSourceURL: item.mixdownURL, createdAt: Date(timeIntervalSince1970: 1))
    }

    static func item(_ id: String, directory: URL) -> RecordingLibraryItem {
        RecordingLibraryItem(id: id, title: "meeting \(id)", createdAt: Date(timeIntervalSince1970: 1),
                             duration: .seconds(10), mixdownURL: directory.appendingPathComponent("\(id)_mix.m4a"),
                             systemAudioURL: nil, microphoneURL: nil,
                             screenCaptureURL: directory.appendingPathComponent("\(id)_screen.mp4"),
                             fileExistence: RecordingLibraryFileExistence(mixdownExists: true, systemAudioExists: false,
                                                                        microphoneExists: false, screenCaptureExists: true))
    }
}

// Deliberately ignores task cancellation so stale callback protection is exercised.
private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ControlledLibraryStore: RecordingLibraryStoring {
    private var items: [RecordingLibraryItem] = []
    private var gate: SuspensionGate?
    private var failing = false

    func setItems(_ items: [RecordingLibraryItem]) { self.items = items }

    func holdNextRead(_ gate: SuspensionGate, failing: Bool = false) {
        self.gate = gate
        self.failing = failing
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        let captured = items
        let suspension = gate
        let failure = failing
        gate = nil
        failing = false
        await suspension?.wait()
        if failure {
            throw SummaryError.persistenceFailed("delayed enumeration error")
        }
        return captured
    }
}

private actor ControlledSummaryStore: MeetingSummaryStoring {
    private var transcripts: [URL: TranscriptResult] = [:]
    private var summaries: [URL: MeetingSummary] = [:]
    private var transcriptGate: SuspensionGate?
    private var summaryGate: SuspensionGate?
    private var failingRead = false
    private var saveGate: SuspensionGate?
    private(set) var cancelledReads = 0
    private(set) var savedSummaries: [(item: RecordingLibraryItem, summary: MeetingSummary)] = []

    func seed(_ transcript: TranscriptResult, summary: MeetingSummary, for item: RecordingLibraryItem) {
        transcripts[item.mixdownURL] = transcript
        summaries[item.mixdownURL] = summary
    }

    func holdNextRead(summary: Bool, gate: SuspensionGate, failing: Bool) {
        if summary {
            summaryGate = gate
        } else {
            transcriptGate = gate
        }
        failingRead = failing
    }

    func holdNextSummarySave(_ gate: SuspensionGate) { saveGate = gate }

    func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? {
        let captured = transcripts[item.mixdownURL]
        let gate = transcriptGate
        transcriptGate = nil
        try await finishRead(gate)
        return captured
    }

    func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        let captured = summaries[item.mixdownURL]
        let gate = summaryGate
        summaryGate = nil
        try await finishRead(gate)
        return captured
    }

    private func finishRead(_ gate: SuspensionGate?) async throws {
        guard let gate else {
            return
        }
        let failure = failingRead
        failingRead = false
        await gate.wait()
        if Task.isCancelled {
            cancelledReads += 1
        }
        if failure {
            throw SummaryError.persistenceFailed("delayed read error")
        }
    }

    func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {
        let gate = saveGate
        saveGate = nil
        await gate?.wait()
        summaries[item.mixdownURL] = summary
        savedSummaries.append((item, summary))
    }

    func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {
        transcripts[item.mixdownURL] = transcript
    }
}

private actor ControlledProcessingServices: AudioTranscriptionService, TranscriptSummaryService, ScreenOCRServicing {
    private var summaryGate: SuspensionGate?
    private var nextResult: TranscriptSummaryResult?
    private var ocrGate: SuspensionGate?

    func holdNextSummary(_ gate: SuspensionGate, result: TranscriptSummaryResult? = nil) {
        summaryGate = gate
        nextResult = result
    }

    func holdNextOCR(_ gate: SuspensionGate) { ocrGate = gate }

    nonisolated func transcribe(audioURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(TranscriptResult(text: "generated speech", localeIdentifier: locale.identifier,
                                                         sourceURL: audioURL)))
            continuation.finish()
        }
    }

    func recognize(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult {
        let gate = ocrGate
        ocrGate = nil
        await gate?.wait()
        throw ScreenOCRError.invalidVideo
    }

    func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        await summarize(transcript, template: .builtIn, progress: { _ in })
    }

    func summarize(_ transcript: TranscriptResult, template: SummaryTemplate,
                   progress: SummaryProgressHandler) async -> TranscriptSummaryResult {
        let gate = summaryGate
        let result = nextResult ?? .summarized(MeetingSummary(
            summary: "generated \(transcript.text)", topics: [], actionItems: [], transcriptSourceURL: transcript.sourceURL
        ))
        summaryGate = nil
        nextResult = nil
        await gate?.wait()
        await progress(.chunk(completed: 1, total: 1))
        return result
    }
}
