import Foundation
import Testing
@testable import meet_log

@MainActor
struct LibraryProcessingTests {
    @Test func cancelledProcessingKeepsManagementBlockedUntilWorkerExits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        await fixture.services.configure(paused: true)
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(.summary)
        try await waitFor { await fixture.services.waiting }
        #expect(LibraryActivity.isBusy(fixture.item.mixdownURL))
        model.cancelProcessing()
        model.prepareTrash(.all)
        #expect(model.trashPlan == nil)
        #expect(model.managementMessage != nil)
        #expect(LibraryActivity.isBusy(fixture.item.mixdownURL))
        await fixture.services.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.item.mixdownURL) }
    }

    @Test func savedEditsReachReloadSearchExportAndSummaryOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.beginTranscriptEditing()
        model.editDraft?.segmentTexts[0] = "corrected terminology"
        model.editDraft?.screenTexts[0] = "corrected screen"
        #expect(model.transcript == fixture.original)
        await model.saveEdits()
        #expect(model.editError == nil)
        #expect(model.editDraft == nil)
        let edited = try #require(model.transcript)
        #expect(edited.text == "自分: corrected terminology")
        #expect(edited.segments[0].timestamp == 2)
        #expect(model.summaryInputWarning != nil)
        let reloaded = fixture.model()
        await reloaded.load()
        try await settled(reloaded)
        #expect(reloaded.transcript == edited)
        let document = try #require(reloaded.exportDocumentForSelectedItem())
        let markdown = MeetingExportFormatter().markdown(for: document, sections: [.transcript])
        #expect(markdown.contains("corrected terminology"))
        #expect(markdown.contains("corrected screen"))
        model.searchQuery = "corrected terminology"
        try await waitFor { @MainActor in model.searchProgress?.isComplete == true }
        #expect(model.searchResults.map(\.item.id) == [fixture.item.id])
        reloaded.runProcessing(.summary)
        try await settled(reloaded)
        #expect(reloaded.processingConfirmation == nil)
        #expect(await fixture.services.summaryInputs.first == edited)
        #expect(await fixture.services.speechCalls == 0)
        #expect(await fixture.services.ocrCalls == 0)
    }

    @Test func summaryEditingSupportsLegacyIDsAndRegenerationConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try await fixture.storage.save(MeetingSummary(
            summary: "old", topics: [MeetingTopic(title: "old topic")],
            actionItems: [MeetingActionItem(title: "old todo")], transcriptSourceURL: fixture.item.mixdownURL,
            createdAt: Date(timeIntervalSince1970: 1000)
        ), for: fixture.item)
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.beginSummaryEditing()
        model.editDraft?.text = "corrected summary"
        model.editDraft?.topics[0].title = "corrected topic"
        model.editDraft?.actionItems[0].owner = "corrected owner, second owner"
        model.editDraft?.actionItems[0].dueDateText = "next Friday"
        await model.saveEdits()
        #expect(model.editError == nil)
        let edited = try #require(model.savedSummary)
        #expect(edited.editedAt != nil)
        model.loadSummaryForSelectedItem()
        try await settled(model)
        #expect(model.savedSummary == edited)
        model.searchQuery = "second owner"
        try await waitFor { @MainActor in model.searchProgress?.isComplete == true }
        #expect(model.searchResults.map(\.item.id) == [fixture.item.id])
        #expect(model.exportDocumentForSelectedItem()?.summary == edited)
        model.runProcessing(.summary)
        try await settled(model)
        #expect(model.processingConfirmation != nil)
        #expect(await fixture.services.totalCalls == 0)
        model.cancelProcessingConfirmation()
        #expect(model.savedSummary == edited)
        model.runProcessing(.summary)
        try await settled(model)
        model.confirmProcessingOverwrite()
        try await settled(model)
        #expect(model.savedSummary?.summary == "new summary")
        #expect(model.savedSummary?.editedAt == nil)
    }

    @Test(arguments: [true, false])
    func editCancellationAndFailedSaveKeepOriginalAndDraft(editTranscript: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model(storage: FailingSaveStore(base: fixture.storage))
        await model.load()
        try await settled(model)
        if editTranscript {
            model.beginTranscriptEditing()
            model.editDraft?.segmentTexts[0] = "correction"
        } else {
            model.beginSummaryEditing()
            model.editDraft?.text = "correction"
        }
        let draft = model.editDraft
        model.select(fixture.other)
        #expect(model.selectedItem?.id == fixture.item.id)
        model.loadSummaryForSelectedItem()
        model.runProcessing(.all)
        #expect(model.editDraft == draft)
        #expect(await fixture.services.totalCalls == 0)
        await model.saveEdits()
        #expect(model.editError != nil)
        #expect(model.editDraft == draft)
        #expect(!model.isSavingEdits)
        #expect(model.transcript == fixture.original)
        #expect(model.savedSummary == fixture.summary)
        model.discardEdits()
        #expect(model.editDraft == nil)
        #expect(try await fixture.storage.transcript(for: fixture.item) == fixture.original)
        #expect(try await fixture.storage.summary(for: fixture.item) == fixture.summary)
    }

    @Test func stageRerunsConfirmOnlyAffectedManualLayers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.beginTranscriptEditing()
        model.editDraft?.segmentTexts[0] = "audio edit"
        model.editDraft?.screenTexts[0] = "screen edit"
        await model.saveEdits()
        let audioEditDate = model.transcript?.audioEditedAt
        model.runProcessing(.screenOCR)
        try await settled(model)
        #expect(model.processingConfirmation?.message.contains("画面OCR") == true)
        #expect(await fixture.services.ocrCalls == 0)
        model.confirmProcessingOverwrite()
        try await settled(model)
        #expect(model.transcript?.audioEditedAt == audioEditDate)
        #expect(model.transcript?.screenEditedAt == nil)
        #expect(model.transcript?.text == "自分: audio edit")
        model.runProcessing(.transcription)
        try await settled(model)
        #expect(model.processingConfirmation?.message.contains("音声") == true)
        #expect(await fixture.services.speechCalls == 0)
        model.cancelProcessingConfirmation()
        #expect(model.transcript?.text == "自分: audio edit")
    }

    @Test func externalChangeDuringEditingIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.beginTranscriptEditing()
        model.editDraft?.segmentTexts[0] = "local edit"
        let external = TranscriptResult(text: "external", localeIdentifier: "ja-JP", sourceURL: fixture.item.mixdownURL)
        try await fixture.storage.save(external, for: fixture.item)
        await model.saveEdits()
        #expect(model.editError != nil)
        #expect(model.editDraft?.segmentTexts[0] == "local edit")
        #expect(try await fixture.storage.transcript(for: fixture.item) == external)
    }

    @Test func summaryOnlyUsesSavedManualEditsWithoutSpeechOrOCR() async throws {
        let fixture = try Fixture(audio: false)
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        // Edit after loading to verify the run reads the persisted input again.
        let url = fixture.directory.appendingPathComponent("a_transcript.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        try markdown.replacingOccurrences(of: "## Text\n\noriginal", with: "## Text\n\nmanual correction")
            .write(to: url, atomically: true, encoding: .utf8)
        model.runProcessing(.summary)
        try await settled(model)

        let inputs = await fixture.services.summaryInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.text == "manual correction")
        #expect(inputs.first?.screenSegments == fixture.original.screenSegments)
        #expect(inputs.first?.segments.isEmpty == true)
        #expect(await fixture.services.speechCalls == 0)
        #expect(await fixture.services.ocrCalls == 0)
        #expect(model.savedSummary?.summary == "new summary")
        #expect(model.summaryInputWarning == nil)
        let stored = try await fixture.storage.summary(for: fixture.item)
        #expect(stored?.inputFingerprint == inputs.first?.summaryInputFingerprint)
    }

    @Test func ocrOnlyPreservesAudioEditsAndMarksSummaryStaleAcrossReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(.screenOCR)
        try await settled(model)

        let stored = try #require(try await fixture.storage.transcript(for: fixture.item))
        #expect(stored.text == fixture.original.text)
        #expect(stored.segments == fixture.original.segments)
        #expect(stored.screenSegments.first?.text == "new screen")
        #expect(await fixture.services.speechCalls == 0)
        #expect(await fixture.services.summaryInputs.isEmpty)
        #expect(model.savedSummary == fixture.summary)
        #expect(model.summaryInputWarning?.contains("更新前") == true)
        model.loadSummaryForSelectedItem()
        try await settled(model)
        #expect(model.summaryInputWarning?.contains("更新前") == true)
    }

    @Test func transcriptionOnlyPreservesScreenAndPreviousSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(.transcription)
        try await settled(model)
        #expect(model.transcript?.text == "new speech")
        #expect(model.transcript?.screenSegments == fixture.original.screenSegments)
        #expect(model.savedSummary == fixture.summary)
        #expect(await fixture.services.ocrCalls == 0)
        #expect(await fixture.services.summaryInputs.isEmpty)
    }

    @Test(arguments: [LibraryProcessingStage.transcription, .screenOCR, .summary])
    func failureKeepsPreviousResultsAndAllowsRetry(stage: LibraryProcessingStage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        await fixture.services.configure(failing: true)
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(stage)
        try await settled(model)
        guard case .failed = model.summaryState else {
            Issue.record("Expected stage failure")
            return
        }
        #expect(model.transcript == fixture.original)
        #expect(model.savedSummary == fixture.summary)
        #expect(try await fixture.storage.transcript(for: fixture.item) == fixture.original)
        #expect(try await fixture.storage.summary(for: fixture.item) == fixture.summary)
        await fixture.services.configure(failing: false)
        model.runProcessing(stage)
        try await settled(model)
        if case .failed = model.summaryState {
            Issue.record("Retry must succeed")
        }
    }

    @Test(arguments: [LibraryProcessingStage.transcription, .screenOCR, .summary])
    func cancellationDiscardsLateResultsAndPreventsDuplicateRuns(stage: LibraryProcessingStage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        await fixture.services.configure(paused: true)
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(stage)
        try await waitFor { await fixture.services.waiting }
        model.runProcessing(stage)
        #expect(await fixture.services.totalCalls == 1)
        #expect(model.savedSummary == fixture.summary)
        #expect(model.transcript == fixture.original)
        model.cancelProcessing()
        #expect(model.summaryState == .cancelled)
        await fixture.services.release()
        try await waitFor { await fixture.services.finishedCalls == 1 }
        // Allow a late service completion to reach the cancelled orchestration task.
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.savedSummary == fixture.summary)
        #expect(try await fixture.storage.transcript(for: fixture.item) == fixture.original)
        #expect(try await fixture.storage.summary(for: fixture.item) == fixture.summary)
        model.runProcessing(stage)
        try await settled(model)
        #expect(await fixture.services.totalCalls == 2)
    }

    @Test(arguments: [LibraryProcessingStage.transcription, .screenOCR, .summary])
    func switchingAwayAndBackRejectsLateResultFromPreviousRun(stage: LibraryProcessingStage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        await fixture.services.configure(paused: true)
        let model = fixture.model()
        await model.load()
        try await settled(model)
        model.runProcessing(stage)
        try await waitFor { await fixture.services.waiting }
        model.select(fixture.other)
        try await settled(model)
        #expect(model.transcript == nil)
        #expect(model.savedSummary == nil)
        model.select(fixture.item)
        try await settled(model)
        await fixture.services.release()
        try await waitFor { await fixture.services.finishedCalls == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.transcript == fixture.original)
        #expect(model.savedSummary == fixture.summary)
        #expect(try await fixture.storage.transcript(for: fixture.other) == nil)
        #expect(try await fixture.storage.summary(for: fixture.other) == nil)
        #expect(try await fixture.storage.summary(for: fixture.item) == fixture.summary)
        #expect(try await fixture.storage.transcript(for: fixture.item) == fixture.original)
    }

    @Test func missingInputsProvideReasonsWithoutCallingServices() async throws {
        let fixture = try Fixture(audio: false, video: false)
        defer { fixture.remove() }
        let model = fixture.model()
        await model.load()
        try await settled(model)
        for stage in LibraryProcessingStage.allCases {
            #expect(model.unavailableReason(for: stage) != nil)
            model.runProcessing(stage)
            try await settled(model)
            guard case .failed = model.summaryState else {
                Issue.record("Expected missing-input failure for \(stage)")
                continue
            }
        }
        #expect(await fixture.services.totalCalls == 0)
    }

    @Test func saveFailureKeepsPriorTranscriptAndSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model(storage: FailingSaveStore(base: fixture.storage))
        await model.load()
        try await settled(model)
        for stage in [LibraryProcessingStage.transcription, .screenOCR, .summary] {
            model.runProcessing(stage)
            try await settled(model)
            guard case .failed = model.summaryState else {
                Issue.record("Expected persistence failure")
                continue
            }
            #expect(model.transcript == fixture.original)
            #expect(model.savedSummary == fixture.summary)
            #expect(try await fixture.storage.transcript(for: fixture.item) == fixture.original)
            #expect(try await fixture.storage.summary(for: fixture.item) == fixture.summary)
        }
    }

    @Test func missingSavedInputDoesNotEraseDisplayedSuccessfulResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let model = fixture.model()
        await model.load()
        try await settled(model)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("a_transcript.md"))
        model.runProcessing(.summary)
        try await settled(model)
        #expect(model.transcript == fixture.original)
        #expect(model.savedSummary == fixture.summary)
        #expect(await fixture.services.totalCalls == 0)
    }

    @Test func editableTextPreservesMarkdownHeadingsAndComments() throws {
        let original = TranscriptResult(
            text: "## Agenda\nA\n<!-- note -->", localeIdentifier: "ja-JP",
            sourceURL: URL(fileURLWithPath: "/tmp/a.m4a")
        )
        let markdown = TranscriptMarkdownCodec.encode(original, recordingID: "a")
        #expect(try TranscriptMarkdownCodec.decode(markdown) == original)
        let edited = markdown.replacingOccurrences(of: "## Agenda\nA", with: "## Agenda\nB")
        #expect(try TranscriptMarkdownCodec.decode(edited).text == "## Agenda\nB\n<!-- note -->")
    }

    @Test func legacySummaryRemainsReadableWithoutFingerprint() throws {
        let summary = MeetingSummary(summary: "legacy", topics: [], actionItems: [], transcriptSourceURL: nil)
        let decoded = try MeetingSummaryMarkdownCodec.decode(MeetingSummaryMarkdownCodec.encode(summary, recordingID: "a"))
        #expect(decoded.summary == "legacy")
        #expect(decoded.inputFingerprint == nil)
    }

    private func settled(_ model: LibraryViewModel) async throws {
        try await waitFor { @MainActor in !model.isSummaryBusy }
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
    let directory: URL
    let item: RecordingLibraryItem
    let other: RecordingLibraryItem
    let storage = MeetingSummarySidecarStore()
    let services = ProcessingServices()

    init(audio: Bool = true, video: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        item = Self.item("a", directory: directory, audio: audio, video: video)
        other = Self.item("b", directory: directory, audio: audio, video: video)
    }

    var original: TranscriptResult {
        TranscriptResult(
            text: "original", localeIdentifier: "ja-JP", sourceURL: item.mixdownURL,
            segments: [TranscriptSegment(text: "original", timestamp: 2, duration: 3, speaker: .me)],
            screenSegments: [ScreenTranscriptSegment(text: "saved screen", timestamp: 0, duration: 10)]
        )
    }

    var summary: MeetingSummary {
        MeetingSummary(
            summary: "saved summary", topics: [], actionItems: [], transcriptSourceURL: item.mixdownURL,
            createdAt: Date(timeIntervalSince1970: 1000)
        ).recording(input: original)
    }

    func seed() async throws {
        try await storage.save(original, for: item)
        try await storage.save(summary, for: item)
    }

    func model(storage override: MeetingSummaryStoring? = nil) -> LibraryViewModel {
        LibraryViewModel(
            store: ProcessingLibraryStore(items: [item, other]),
            transcriptionService: services, summaryService: services,
            summaryStore: override ?? storage, screenOCRService: services
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func item(_ id: String, directory: URL, audio: Bool, video: Bool) -> RecordingLibraryItem {
        RecordingLibraryItem(
            id: id, title: id, createdAt: .now, duration: .seconds(10),
            mixdownURL: directory.appendingPathComponent("\(id)_mix.m4a"),
            systemAudioURL: nil, microphoneURL: nil,
            screenCaptureURL: video ? directory.appendingPathComponent("\(id)_screen.mp4") : nil,
            fileExistence: RecordingLibraryFileExistence(
                mixdownExists: audio, systemAudioExists: false, microphoneExists: false, screenCaptureExists: video
            )
        )
    }
}

private struct ProcessingLibraryStore: RecordingLibraryStoring {
    let items: [RecordingLibraryItem]
    func recordings() async throws -> [RecordingLibraryItem] { items }
}

private struct FailingSaveStore: MeetingSummaryStoring {
    let base: MeetingSummarySidecarStore
    func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? { try await base.transcript(for: item) }
    func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? { try await base.summary(for: item) }
    func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {
        throw SummaryError.persistenceFailed("disk full")
    }
    func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {
        throw SummaryError.persistenceFailed("disk full")
    }
}

private actor ProcessingServices: AudioTranscriptionService, ScreenOCRServicing, TranscriptSummaryService {
    private(set) var speechCalls = 0
    private(set) var ocrCalls = 0
    private(set) var summaryInputs: [TranscriptResult] = []
    private(set) var finishedCalls = 0
    private var failing = false
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    var totalCalls: Int { speechCalls + ocrCalls + summaryInputs.count }

    func configure(failing: Bool = false, paused: Bool = false) {
        self.failing = failing
        self.paused = paused
    }

    func release() {
        paused = false
        continuation?.resume()
        continuation = nil
    }

    private func gate() async {
        if paused {
            await withCheckedContinuation { continuation = $0 }
        }
        finishedCalls += 1
    }

    nonisolated func transcribe(audioURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { stream in
            Task {
                do {
                    stream.yield(.completed(try await speech(audioURL)))
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
        }
    }

    private func speech(_ url: URL) async throws -> TranscriptResult {
        speechCalls += 1
        await gate()
        if failing {
            throw TranscriptionError.emptyResult
        }
        return TranscriptResult(text: "new speech", localeIdentifier: "ja-JP", sourceURL: url)
    }

    func recognize(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult {
        ocrCalls += 1
        await gate()
        if failing {
            throw ScreenOCRError.invalidVideo
        }
        return ScreenOCRResult(
            segments: [ScreenTranscriptSegment(text: "new screen", timestamp: 0, duration: 10)],
            report: ScreenOCRReport(sampledFrames: 5, recognizedFrames: 1, elapsedSeconds: 1)
        )
    }

    func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        summaryInputs.append(transcript)
        await gate()
        if failing {
            return .failed(.invalidStructuredOutput)
        }
        return .summarized(MeetingSummary(
            summary: "new summary", topics: [], actionItems: [], transcriptSourceURL: transcript.sourceURL
        ))
    }
}
