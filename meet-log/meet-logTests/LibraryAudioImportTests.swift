import AVFoundation
import Foundation
import Testing
@testable import meet_log

@MainActor
struct LibraryAudioImportTests {
    @Test func pickerSelectionProcessesManagedAudioAndPersistsResults() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.writeWav()
        let access = AccessTracker()
        let services = ImportProcessingServices()
        let model = fixture.model(importer: access.service(), services: services)
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.success(fixture.source))
        try await waitFor { model.audioImportState != .importing && !model.isSummaryBusy }

        let item = try #require(model.selectedItem)
        #expect(item.mixdownURL != fixture.source)
        #expect(item.title == fixture.source.lastPathComponent)
        #expect(item.mixdownURL.pathExtension == "wav")
        #expect(try Data(contentsOf: item.mixdownURL) == Data(contentsOf: fixture.source))
        #expect(access.starts == 1 && access.stops == 1)
        #expect(await services.urls == [item.mixdownURL])
        #expect(model.transcript?.text == "imported transcript")
        #expect(model.savedSummary?.summary == "imported summary")
        #expect(try await fixture.storage.transcript(for: item) == model.transcript)
        #expect(try await fixture.storage.summary(for: item) == model.savedSummary)

        // Removing the external source cannot break reload, playback URLs or retry.
        try FileManager.default.removeItem(at: fixture.source)
        let restored = try #require(try await fixture.store.recordings().first)
        #expect(restored.id == item.id)
        #expect(restored.title == item.title)
        // FileManager enumeration and URL standardization can spell the same
        // macOS temporary file as /private/var/... or /var/.... Compare identity.
        #expect(restored.mixdownURL.resolvingSymlinksInPath() == item.mixdownURL.resolvingSymlinksInPath())
        model.runProcessing(.all)
        try await waitFor { !model.isSummaryBusy }
        #expect(await services.urls == [item.mixdownURL, item.mixdownURL])
        #expect(model.savedSummary?.summary == "imported summary")
    }

    @Test(arguments: ["mp3", "m4a", "wav"])
    func copyPreservesFormatAndRepeatedNamesRemainDistinct(fileExtension: String) async throws {
        let fixture = try ImportFixture(fileExtension: fileExtension)
        defer { fixture.remove() }
        try Data([1, 2, 3, 4]).write(to: fixture.source)
        let access = AccessTracker()
        let service = access.service(validator: ImportValidationStub())
        let first = try await service.importAudio(from: fixture.source, to: fixture.output)
        let second = try await service.importAudio(from: fixture.source, to: fixture.output)

        #expect(first.id != second.id)
        #expect(first.mixdownURL != second.mixdownURL)
        #expect(first.mixdownURL.pathExtension == fileExtension)
        #expect(PlaybackSource(item: first).recordingURL == first.mixdownURL)
        #expect(try Data(contentsOf: first.mixdownURL) == Data(contentsOf: fixture.source))
        #expect(try await fixture.store.recordings().count == 2)
        #expect(access.starts == 2 && access.stops == 2)

        let plan = try LibraryTrashService().plan(for: first, scope: .all)
        #expect(plan.files.contains { $0.url == first.mixdownURL })
        #expect(!plan.files.contains { $0.url == fixture.source })
        #expect(!plan.files.contains { $0.url == second.mixdownURL })
        let activity = LibraryActivity.begin(first.mixdownURL)
        defer { LibraryActivity.end(activity) }
        #expect(throws: LibraryManagementError.self) {
            try LibraryTrashService().execute(plan)
        }
    }

    @Test(arguments: [AudioImportError.emptyFile, .permissionDenied("denied"), .unsupportedFormat("txt")])
    func validationFailureReleasesAccessWithoutPublishing(error: AudioImportError) async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let access = AccessTracker()
        let services = ImportProcessingServices()
        let model = fixture.model(
            importer: access.service(validator: ImportValidationStub(error: error)), services: services
        )
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.success(fixture.source))
        try await waitFor { model.audioImportState != .importing }

        guard case .failed = model.audioImportState else {
            Issue.record("Expected import failure")
            return
        }
        #expect(access.starts == 1 && access.stops == 1)
        #expect(try await fixture.store.recordings().isEmpty)
        #expect(await services.urls.isEmpty)
        #expect(model.canImportAudio)
    }

    @Test func destinationFailureRemovesStagingAndReleasesAccess() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try Data([1]).write(to: fixture.source)
        try Data([2]).write(to: fixture.output) // A file cannot be an output directory.
        let access = AccessTracker()
        await #expect(throws: (any Error).self) {
            try await access.service(validator: ImportValidationStub())
                .importAudio(from: fixture.source, to: fixture.output)
        }
        #expect(access.starts == 1 && access.stops == 1)
        #expect(try Data(contentsOf: fixture.source) == Data([1]))
        #expect(try Data(contentsOf: fixture.output) == Data([2]))
    }

    @Test func cancellationWaitsForValidationThenCleansUpAndRejectsLateCompletion() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try Data([1]).write(to: fixture.source)
        let gate = ImportValidationGate()
        let access = AccessTracker()
        let services = ImportProcessingServices()
        let model = fixture.model(importer: access.service(validator: gate), services: services)
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.success(fixture.source))
        try await waitFor { await gate.waiting }
        #expect(access.starts == 1 && access.stops == 0)
        model.cancelAudioImport() // Used by screen departure and destination changes.
        await gate.release()
        try await waitFor { access.stops == 1 }

        #expect(model.audioImportState == .cancelled)
        #expect(model.selectedItem == nil)
        #expect(try await fixture.store.recordings().isEmpty)
        #expect(await services.urls.isEmpty)
        #expect(model.canImportAudio)
    }

    @Test func pickerCancellationAndLateResultAfterDepartureDoNotStartImport() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let access = AccessTracker()
        let model = fixture.model(importer: access.service(), services: ImportProcessingServices())
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.failure(CocoaError(.userCancelled)))
        #expect(model.audioImportState == .idle)
        model.presentAudioImporter()
        model.cancelAudioImport()
        model.handleAudioImporterResult(.success(fixture.source))
        #expect(model.audioImportState == .idle)
        #expect(!model.isAudioImporterPresented)
        #expect(access.starts == 0)
    }

    @Test func importedProcessingFailureKeepsCopyAndTranscriptForRetry() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.writeWav()
        let services = ImportProcessingServices()
        await services.failSummary(true)
        let model = fixture.model(importer: LibraryAudioImportService(), services: services)
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.success(fixture.source))
        try await waitFor { model.audioImportState != .importing && !model.isSummaryBusy }
        guard case .failed = model.summaryState else {
            Issue.record("Expected summary failure")
            return
        }
        #expect(model.transcript?.text == "imported transcript")
        #expect(model.savedSummary == nil)
        let item = try #require(model.selectedItem)
        #expect(FileManager.default.fileExists(atPath: item.mixdownURL.path))
        await services.failSummary(false)
        model.runProcessing(.summary)
        try await waitFor { !model.isSummaryBusy }
        #expect(model.savedSummary?.summary == "imported summary")
        #expect(await services.urls == [item.mixdownURL])
    }

    @Test func cancellingImportedProcessingRetainsCopyForRetry() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.writeWav()
        let services = ImportProcessingServices()
        await services.pauseSummary()
        let model = fixture.model(importer: LibraryAudioImportService(), services: services)
        await model.load()
        model.presentAudioImporter()
        model.handleAudioImporterResult(.success(fixture.source))
        try await waitFor { await services.waiting }
        #expect(model.summaryState == .summaryProgress(.chunk(completed: 1, total: 2)))
        let item = try #require(model.selectedItem)
        model.cancelProcessing()
        await services.releaseSummary()
        try await waitFor { !LibraryActivity.isBusy(item.mixdownURL) }
        #expect(model.summaryState == .cancelled)
        #expect(try await fixture.storage.summary(for: item) == nil)
        #expect(try await fixture.storage.transcript(for: item)?.text == "imported transcript")
        model.runProcessing(.summary)
        try await waitFor { !model.isSummaryBusy }
        #expect(model.savedSummary?.summary == "imported summary")
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        // Allow cold framework initialization on the main actor during parallel CI.
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw ImportTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ImportTestError: Error { case timeout }

@MainActor
private struct ImportFixture {
    let root: URL
    let source: URL
    let output: URL
    let storage = MeetingSummarySidecarStore()
    var store: OutputDirectoryRecordingLibraryStore {
        OutputDirectoryRecordingLibraryStore(outputDirectoryURL: output)
    }

    init(fileExtension: String = "wav") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("meeting.\(fileExtension)")
        output = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeWav() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }

    func model(importer: LibraryAudioImporting, services: ImportProcessingServices) -> LibraryViewModel {
        LibraryViewModel(
            store: store, transcriptionService: services, summaryService: services,
            summaryStore: storage, audioImporter: importer, importDirectory: { output }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class AccessTracker {
    var starts = 0
    var stops = 0

    func service(validator: AudioFileImporting = AVAudioFileImporter()) -> LibraryAudioImportService {
        LibraryAudioImportService(validator: validator, startAccess: { _ in
            self.starts += 1
            return true
        }, stopAccess: { _ in self.stops += 1 })
    }
}

private nonisolated struct ImportValidationStub: AudioFileImporting {
    var error: AudioImportError?
    func importAudio(from url: URL) async throws -> AudioImportItem {
        if let error {
            throw error
        }
        return AudioImportItem(
            url: url, fileName: url.lastPathComponent, fileExtension: url.pathExtension.lowercased(),
            byteSize: 4, duration: .seconds(1), channelCount: 1, sampleRate: 44_100
        )
    }
}

private actor ImportValidationGate: AudioFileImporting {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    nonisolated func importAudio(from url: URL) async throws -> AudioImportItem {
        await wait()
        // Intentionally ignores cancellation so the caller must reject the late result.
        return try await ImportValidationStub().importAudio(from: url)
    }
    private func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ImportProcessingServices: AudioTranscriptionService, TranscriptSummaryService {
    private(set) var urls: [URL] = []
    private var failing = false
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    func failSummary(_ value: Bool) { failing = value }
    func pauseSummary() { paused = true }
    func releaseSummary() {
        paused = false
        continuation?.resume()
        continuation = nil
    }

    nonisolated func transcribe(audioURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { stream in
            Task {
                await record(audioURL)
                stream.yield(.completed(TranscriptResult(
                    text: "imported transcript", localeIdentifier: locale.identifier, sourceURL: audioURL
                )))
                stream.finish()
            }
        }
    }
    private func record(_ url: URL) { urls.append(url) }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        await result(transcript)
    }
    nonisolated func summarize(
        _ transcript: TranscriptResult, progress: SummaryProgressHandler
    ) async -> TranscriptSummaryResult {
        await progress(.chunk(completed: 1, total: 2))
        await waitIfPaused()
        return await result(transcript)
    }
    private func waitIfPaused() async {
        if paused {
            await withCheckedContinuation { continuation = $0 }
        }
    }
    private func result(_ transcript: TranscriptResult) -> TranscriptSummaryResult {
        if failing {
            return .failed(.invalidStructuredOutput)
        }
        return .summarized(MeetingSummary(
            summary: "imported summary", topics: [], actionItems: [], transcriptSourceURL: transcript.sourceURL
        ))
    }
}
