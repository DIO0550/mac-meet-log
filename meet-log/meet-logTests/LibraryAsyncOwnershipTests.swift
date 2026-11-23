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

    @Test(arguments: [false, true])
    func mixCompletionPreservesAnotherRecordingSummary(failingExport: Bool) async throws {
        let fixture = Fixture()
        var a = fixture.aNeedingMix
        a.tags = ["keep"]
        await fixture.seed([a, fixture.b])
        let model = fixture.model()
        await model.load()

        let exportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: a.mixdownURL, at: exportGate, failing: failingExport)
        model.remixSelectedItem()
        #expect(model.remixState == .mixing(a.id))
        try await waitFor { await exportGate.isWaiting }

        model.select(fixture.b)
        try await waitFor { @MainActor in !model.isSummaryBusy }
        let summaryGate = SuspensionGate()
        await fixture.services.holdNextSummary(summaryGate)
        model.runProcessing(.summary)
        try await waitFor { await summaryGate.isWaiting }

        // The scanner may return other items in a different order with older metadata.
        let scannedA = fixture.aNeedingMix.withPublishedMix(duration: .seconds(42))
        await fixture.library.setItems([fixture.b, scannedA])
        await exportGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }

        #expect(model.selectedItem == fixture.b)
        #expect(model.summaryState == .summarizing)
        #expect(model.remixState == .idle)
        #expect(model.items.map(\.id) == [a.id, fixture.b.id])
        #expect(model.items.first?.tags == ["keep"])
        #expect(await fixture.storage.savedSummaries.isEmpty)

        await summaryGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(fixture.b.mixdownURL) }
        #expect(model.savedSummary?.summary == "generated B")
        #expect(await fixture.storage.savedSummaries.map(\.item.mixdownURL) == [fixture.b.mixdownURL])

        model.select(a)
        if failingExport {
            #expect(model.selectedItem == a)
            #expect(model.remixState == .failed(a.id, ControlledMixdownService.Failure.exportFailed.localizedDescription))
        } else {
            let mixed = try #require(model.selectedItem)
            #expect(mixed.mixdownStatus == .mixed)
            #expect(mixed.duration == .seconds(42))
            #expect(mixed.fileExistence.systemAudioExists)
            #expect(PlaybackSource(item: mixed).audioURLs == [a.mixdownURL])
            #expect(model.remixState == .idle)
        }
    }

    @Test(arguments: [false, true])
    func mixCompletionPreservesAnotherRecordingSavedResultRead(summaryRead: Bool) async throws {
        let fixture = Fixture()
        let a = fixture.aNeedingMix
        await fixture.seed([a, fixture.b])
        let model = fixture.model()
        await model.load()

        let exportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: a.mixdownURL, at: exportGate)
        model.remixSelectedItem()
        try await waitFor { await exportGate.isWaiting }

        let readGate = SuspensionGate()
        await fixture.storage.holdNextRead(summary: summaryRead, gate: readGate, failing: false)
        model.select(fixture.b)
        try await waitFor { await readGate.isWaiting }

        await fixture.library.setItems([a.withPublishedMix(duration: .seconds(11)), fixture.b])
        await exportGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }
        #expect(model.items.first?.hasUsableMixdown == true)
        #expect(model.selectedItem == fixture.b)
        #expect(model.summaryState == .loadingSaved)

        await readGate.release()
        try await waitFor { @MainActor in !model.isSummaryBusy }
        #expect(await fixture.storage.cancelledReads == 0)
        expectB(model, fixture: fixture)
    }

    @Test(arguments: [false, true])
    func unverifiedMixKeepsRowAndAllowsRetry(failingRead: Bool) async throws {
        let fixture = Fixture()
        let a = fixture.aNeedingMix
        await fixture.seed([a])
        let model = fixture.model()
        await model.load()

        let readGate = SuspensionGate()
        if failingRead {
            await fixture.library.holdNextRead(readGate, failing: true)
        }
        model.remixSelectedItem()
        if failingRead {
            try await waitFor { await readGate.isWaiting }
            await readGate.release()
        }
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }

        #expect(model.selectedItem == a)
        let verificationMessage = "作成したミックスを確認できませんでした。"
        let readError = SummaryError.persistenceFailed("delayed enumeration error")
        let message = failingRead ? "\(verificationMessage) \(readError.localizedDescription)" : verificationMessage
        #expect(model.remixState == .failed(a.id, message))

        await fixture.library.setItems([a.withPublishedMix(duration: nil)])
        model.remixSelectedItem()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }
        #expect(await fixture.mixdown.destinations == [a.mixdownURL, a.mixdownURL])
        #expect(model.selectedItem?.hasUsableMixdown == true)
        #expect(model.selectedItem?.duration == nil)
        #expect(model.remixState == .idle)
    }

    @Test(arguments: [false, true], [false, true])
    func destinationChangeDiscardsMixUpdates(waitingOnRead: Bool, failing: Bool) async throws {
        let fixture = Fixture()
        let original = fixture.aNeedingMix
        await fixture.seed([original])
        let model = fixture.model()
        await model.load()

        let exportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: original.mixdownURL, at: exportGate, failing: failing && !waitingOnRead)
        model.remixSelectedItem()
        try await waitFor { await exportGate.isWaiting }

        let readGate = SuspensionGate()
        if waitingOnRead {
            await fixture.library.setItems([original.withPublishedMix(duration: .seconds(20))])
            await fixture.library.holdNextRead(readGate, failing: failing)
            await exportGate.release()
            try await waitFor { await readGate.isWaiting }
        }

        let newDirectory = fixture.directory.appendingPathComponent("new")
        let newRecording = Fixture.item(original.id, directory: newDirectory, needsMix: true)
        fixture.directoryRevision += 1
        await fixture.seed([newRecording])
        await model.load()
        let summaryGate = SuspensionGate()
        await fixture.services.holdNextSummary(summaryGate)
        model.runProcessing(.summary)
        try await waitFor { await summaryGate.isWaiting }
        let readsBeforeCompletion = await fixture.library.recordingsCallCount

        if waitingOnRead {
            await readGate.release()
        } else {
            await exportGate.release()
        }
        try await waitFor { @MainActor in !LibraryActivity.isBusy(original.mixdownURL) }
        #expect(await fixture.library.recordingsCallCount == readsBeforeCompletion)
        #expect(model.items == [newRecording])
        #expect(model.selectedItem == newRecording)
        #expect(model.remixState == .idle)
        #expect(model.summaryState == .summarizing)

        await summaryGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(newRecording.mixdownURL) }
        #expect(model.savedSummary?.summary == "generated A")
        #expect(await fixture.storage.savedSummaries.map(\.item.mixdownURL) == [newRecording.mixdownURL])
    }

    @Test(arguments: [false, true])
    func returningToSameDestinationKeepsOldMixExecutionStale(failing: Bool) async throws {
        let fixture = Fixture()
        let original = fixture.aNeedingMix
        await fixture.seed([original])
        let model = fixture.model()
        await model.load()

        let exportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: original.mixdownURL, at: exportGate, failing: failing)
        model.remixSelectedItem()
        try await waitFor { await exportGate.isWaiting }

        fixture.directoryRevision += 1
        let newDirectory = fixture.directory.appendingPathComponent("new")
        await fixture.seed([Fixture.item(original.id, directory: newDirectory)])
        await model.load()
        fixture.directoryRevision += 1
        await fixture.library.setItems([original])
        await model.load()

        let mixed = original.withPublishedMix(duration: .seconds(25))
        if !failing {
            await fixture.library.setItems([mixed])
        }
        await exportGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(original.mixdownURL) }

        #expect(model.items == [original])
        #expect(model.remixState == .idle)
        if !failing {
            await model.load()
            #expect(model.items == [mixed])
        }
    }

    @Test func slowMixReadPreservesFasterMixAndRejectsDuplicateStart() async throws {
        let fixture = Fixture()
        let a = fixture.aNeedingMix
        let c = Fixture.item("C", directory: fixture.directory, needsMix: true)
        await fixture.seed([a, c])
        let model = fixture.model()
        await model.load()

        let aExportGate = SuspensionGate()
        let aReadGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: a.mixdownURL, at: aExportGate)
        model.remixSelectedItem()
        model.remixSelectedItem()
        try await waitFor { await aExportGate.isWaiting }
        let mixedA = a.withPublishedMix(duration: .seconds(20))
        await fixture.library.setItems([mixedA, c])
        await fixture.library.holdNextRead(aReadGate)
        await aExportGate.release()
        try await waitFor { await aReadGate.isWaiting }
        #expect(model.remixState == .mixing(a.id))
        model.remixSelectedItem()

        model.select(c)
        let cExportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: c.mixdownURL, at: cExportGate)
        model.remixSelectedItem()
        #expect(model.remixState == .mixing(c.id))
        try await waitFor { await cExportGate.isWaiting }
        let mixedC = c.withPublishedMix(duration: .seconds(30))
        await fixture.library.setItems([mixedA, mixedC])
        await cExportGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(c.mixdownURL) }
        #expect(model.items == [a, mixedC])

        await aReadGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }
        #expect(await fixture.mixdown.destinations == [a.mixdownURL, c.mixdownURL])
        #expect(model.items == [mixedA, mixedC])
        #expect(model.selectedItem == mixedC)
        #expect(model.remixState == .idle)
    }

    @Test(arguments: [false, true])
    func refreshKeepsAPublishedMixOnlyForRetainedItems(retainsRecording: Bool) async throws {
        let fixture = Fixture()
        let a = fixture.aNeedingMix
        await fixture.seed([a, fixture.b])
        let model = fixture.model()
        await model.load()

        let exportGate = SuspensionGate()
        await fixture.mixdown.holdExport(to: a.mixdownURL, at: exportGate)
        model.remixSelectedItem()
        try await waitFor { await exportGate.isWaiting }

        let refreshGate = SuspensionGate()
        if !retainsRecording {
            await fixture.library.setItems([fixture.b])
        }
        await fixture.library.holdNextRead(refreshGate)
        model.refresh()
        try await waitFor { await refreshGate.isWaiting }

        let mixed = a.withPublishedMix(duration: nil)
        await fixture.library.setItems([mixed, fixture.b])
        await exportGate.release()
        try await waitFor { @MainActor in !LibraryActivity.isBusy(a.mixdownURL) }
        #expect(model.items.first == mixed)

        await refreshGate.release()
        try await waitFor { @MainActor in !model.isSummaryBusy }
        if retainsRecording {
            #expect(model.items == [mixed, fixture.b])
            #expect(model.selectedItem == mixed)
        } else {
            #expect(model.items == [fixture.b])
            expectB(model, fixture: fixture)
        }
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
private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = ControlledSummaryStore()
    let services = ControlledProcessingServices()
    let library = ControlledLibraryStore()
    let mixdown = ControlledMixdownService()
    var directoryRevision = 0
    var a: RecordingLibraryItem { Self.item("A", directory: directory) }
    var b: RecordingLibraryItem { Self.item("B", directory: directory) }
    var aNeedingMix: RecordingLibraryItem { Self.item("A", directory: directory, needsMix: true) }

    func seed(_ items: [RecordingLibraryItem]? = nil) async {
        let items = items ?? [a, b]
        await library.setItems(items)
        for item in items {
            await storage.seed(transcript(item), summary: summary(item), for: item)
        }
    }

    func model() -> LibraryViewModel {
        LibraryViewModel(
            store: library, transcriptionService: services, summaryService: services,
            summaryStore: storage, mixdownService: mixdown, screenOCRService: services,
            directoryRevision: { self.directoryRevision }
        )
    }

    func transcript(_ item: RecordingLibraryItem, text: String? = nil) -> TranscriptResult {
        TranscriptResult(text: text ?? item.id, localeIdentifier: "ja-JP", sourceURL: item.mixdownURL,
                         screenSegments: [ScreenTranscriptSegment(text: "screen \(item.id)", timestamp: 0, duration: 1)])
    }

    func summary(_ item: RecordingLibraryItem, text: String? = nil) -> MeetingSummary {
        MeetingSummary(summary: text ?? "summary \(item.id)", topics: [], actionItems: [],
                       transcriptSourceURL: item.mixdownURL, createdAt: Date(timeIntervalSince1970: 1))
    }

    static func item(_ id: String, directory: URL, needsMix: Bool = false) -> RecordingLibraryItem {
        let system = needsMix ? directory.appendingPathComponent("\(id)_system.m4a") : nil
        return RecordingLibraryItem(
            id: id, title: "meeting \(id)", createdAt: Date(timeIntervalSince1970: 1),
            duration: .seconds(10), mixdownURL: directory.appendingPathComponent("\(id)_mix.m4a"),
            systemAudioURL: system, microphoneURL: nil,
            screenCaptureURL: directory.appendingPathComponent("\(id)_screen.mp4"),
            fileExistence: RecordingLibraryFileExistence(
                mixdownExists: !needsMix, systemAudioExists: needsMix, microphoneExists: false, screenCaptureExists: true
            ),
            mixdownStatus: needsMix ? .needsMix : .mixed
        )
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
    private(set) var recordingsCallCount = 0

    func setItems(_ items: [RecordingLibraryItem]) { self.items = items }

    func holdNextRead(_ gate: SuspensionGate, failing: Bool = false) {
        self.gate = gate
        self.failing = failing
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        recordingsCallCount += 1
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

private actor ControlledMixdownService: RecordingLibraryMixdownServicing {
    enum Failure: LocalizedError {
        case exportFailed

        var errorDescription: String? { "Mix export failed" }
    }

    private struct PendingExport {
        let gate: SuspensionGate
        let failing: Bool
    }

    private var pending: [URL: PendingExport] = [:]
    private(set) var destinations: [URL] = []

    func holdExport(to url: URL, at gate: SuspensionGate, failing: Bool = false) {
        pending[url] = PendingExport(gate: gate, failing: failing)
    }

    func export(systemAudioURL: URL?, microphoneURL: URL?, destinationURL: URL) async throws -> URL {
        destinations.append(destinationURL)
        if let export = pending.removeValue(forKey: destinationURL) {
            await export.gate.wait()
            if export.failing {
                throw Failure.exportFailed
            }
        }
        return destinationURL
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
