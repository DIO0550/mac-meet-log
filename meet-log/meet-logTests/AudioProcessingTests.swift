import Foundation
import Testing
@testable import meet_log

struct AudioProcessingTests {
    @Test func importFailureMapsToPipelineFailure() async {
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .failure(AudioImportError.emptyFile)),
            transcriptionService: FakeAudioTranscriptionService(events: []),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states == [
            .loading,
            .failed(nil, .importFailed(.emptyFile), transcript: nil)
        ])
    }

    @Test func partialTranscriptionUpdatesState() async {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "最終")
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .success(item)),
            transcriptionService: FakeAudioTranscriptionService(events: [
                .partial("途中"),
                .completed(transcript)
            ]),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.contains(.transcribing(item, partialTranscript: "途中")))
    }

    @Test func transcriptionSuccessStartsSummaryAndCompletesWithSummary() async {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "今日は設計を確認しました。")
        let summary = makeSummary()
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .success(item)),
            transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
            summaryService: FakeTranscriptSummaryService(result: .summarized(summary))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.contains(.transcribing(item, partialTranscript: nil)))
        #expect(states.contains(.summarizing(item, transcript)))
        #expect(states.last == .completed(item, transcript, .summarized(summary)))
    }

    @Test func summaryUnavailableCompletesWithTranscriptPreserved() async {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "本文")
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .success(item)),
            transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.deviceNotEligible))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.last == .completed(item, transcript, .unavailable(.deviceNotEligible)))
    }

    @Test func summaryFailureFailsWithTranscriptPreserved() async {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "本文")
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .success(item)),
            transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
            summaryService: FakeTranscriptSummaryService(result: .failed(.invalidStructuredOutput))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.last == .failed(item, .summaryFailed(.invalidStructuredOutput), transcript: transcript))
    }

    @Test func transcriptionFailureMapsToPipelineFailure() async {
        let item = makeImportedItem()
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .success(item)),
            transcriptionService: FakeAudioTranscriptionService(error: TranscriptionError.emptyResult),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.last == .failed(item, .transcriptionFailed(.emptyResult), transcript: nil))
    }

    @Test func cancellationProducesCancelledState() async {
        let job = AudioProcessingJob(
            importer: FakeAudioFileImporter(result: .failure(CancellationError())),
            transcriptionService: FakeAudioTranscriptionService(events: []),
            summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
        )

        let states = await collectStates(from: job.run(audioURL: sampleURL))

        #expect(states.last == .cancelled(nil))
    }

    @MainActor
    @Test func viewModelPickerCancellationReturnsToIdle() {
        let viewModel = AudioProcessingViewModel(job: makeSuccessfulJob())
        viewModel.presentImporter()

        viewModel.handleImporterResult(.failure(CocoaError(.userCancelled)))

        #expect(viewModel.state == .idle)
        #expect(!viewModel.isImporterPresented)
    }

    @MainActor
    @Test func viewModelPickerCancellationKeepsExistingResult() async throws {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "本文")
        let summary = makeSummary()
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: FakeAudioFileImporter(result: .success(item)),
                transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
                summaryService: FakeTranscriptSummaryService(result: .summarized(summary))
            )
        )

        viewModel.process(audioURL: sampleURL)
        try await waitUntil { !viewModel.isProcessing }
        viewModel.presentImporter()
        viewModel.handleImporterResult(.failure(CocoaError(.userCancelled)))

        #expect(viewModel.state == .completed(item, transcript, .summarized(summary)))
        #expect(!viewModel.isImporterPresented)
    }

    @MainActor
    @Test func viewModelSuccessfulProcessingPublishesCompletedState() async throws {
        let item = makeImportedItem()
        let transcript = makeTranscript(text: "本文")
        let summary = makeSummary()
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: FakeAudioFileImporter(result: .success(item)),
                transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
                summaryService: FakeTranscriptSummaryService(result: .summarized(summary))
            )
        )

        viewModel.process(audioURL: sampleURL)
        try await waitUntil { !viewModel.isProcessing }

        #expect(viewModel.state == .completed(item, transcript, .summarized(summary)))
    }

    @MainActor
    @Test func viewModelFailedProcessingExposesRetry() async throws {
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: FakeAudioFileImporter(result: .failure(AudioImportError.emptyFile)),
                transcriptionService: FakeAudioTranscriptionService(events: []),
                summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
            )
        )

        viewModel.process(audioURL: sampleURL)
        try await waitUntil { !viewModel.isProcessing }

        #expect(viewModel.canRetry)
    }

    @MainActor
    @Test func viewModelRetryUsesLastSelectedURL() async throws {
        let importer = RecordingAudioFileImporter(result: .success(makeImportedItem()))
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: importer,
                transcriptionService: FakeAudioTranscriptionService(events: [.completed(makeTranscript(text: "本文"))]),
                summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
            )
        )

        viewModel.process(audioURL: sampleURL)
        try await waitUntil { !viewModel.isProcessing }
        viewModel.retry()
        try await waitUntil { importer.urls.count == 2 && !viewModel.isProcessing }

        #expect(importer.urls == [sampleURL, sampleURL])
    }

    @MainActor
    @Test func viewModelStartingNewJobCancelsOldJob() async throws {
        let importer = SequencedAudioFileImporter(
            results: [
                .failure(CancellationError()),
                .success(makeImportedItem(url: alternateURL))
            ]
        )
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: importer,
                transcriptionService: FakeAudioTranscriptionService(events: [.completed(makeTranscript(text: "本文", sourceURL: alternateURL))]),
                summaryService: FakeTranscriptSummaryService(result: .unavailable(.modelNotReady))
            )
        )

        viewModel.process(audioURL: sampleURL)
        viewModel.process(audioURL: alternateURL)
        try await waitUntil { !viewModel.isProcessing }

        #expect(importer.urls == [sampleURL, alternateURL])
        #expect(viewModel.selectedFileName == alternateURL.lastPathComponent)
    }

    @MainActor
    @Test func copyHelpersOnlyExposeAvailableOutput() async throws {
        let transcript = makeTranscript(text: "本文")
        let summary = makeSummary()
        let viewModel = AudioProcessingViewModel(
            job: AudioProcessingJob(
                importer: FakeAudioFileImporter(result: .success(makeImportedItem())),
                transcriptionService: FakeAudioTranscriptionService(events: [.completed(transcript)]),
                summaryService: FakeTranscriptSummaryService(result: .summarized(summary))
            )
        )

        #expect(viewModel.transcriptText == nil)
        #expect(viewModel.summaryText == nil)

        viewModel.process(audioURL: sampleURL)
        try await waitUntil { !viewModel.isProcessing }

        #expect(viewModel.transcriptText == "本文")
        #expect(viewModel.summaryText?.contains(summary.summary) == true)
    }
}

private let sampleURL = URL(fileURLWithPath: "/tmp/sample.m4a")
private let alternateURL = URL(fileURLWithPath: "/tmp/alternate.m4a")

private func collectStates(from stream: AsyncStream<AudioProcessingJobState>) async -> [AudioProcessingJobState] {
    var states: [AudioProcessingJobState] = []

    for await state in stream {
        states.append(state)
    }

    return states
}

private func makeSuccessfulJob() -> AudioProcessingJob {
    AudioProcessingJob(
        importer: FakeAudioFileImporter(result: .success(makeImportedItem())),
        transcriptionService: FakeAudioTranscriptionService(events: [.completed(makeTranscript(text: "本文"))]),
        summaryService: FakeTranscriptSummaryService(result: .summarized(makeSummary()))
    )
}

private func makeImportedItem(url: URL = sampleURL) -> AudioImportItem {
    AudioImportItem(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        url: url,
        fileName: url.lastPathComponent,
        fileExtension: url.pathExtension,
        byteSize: 1_024,
        duration: .seconds(12),
        channelCount: 1,
        sampleRate: 44_100
    )
}

private func makeTranscript(text: String, sourceURL: URL = sampleURL) -> TranscriptResult {
    TranscriptResult(
        text: text,
        localeIdentifier: "ja-JP",
        sourceURL: sourceURL,
        segments: [TranscriptSegment(text: text, timestamp: 0, duration: 1)]
    )
}

private func makeSummary() -> MeetingSummary {
    MeetingSummary(
        summary: "設計方針を確認した。",
        topics: [
            MeetingTopic(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                title: "設計",
                detail: "オンデバイス処理"
            )
        ],
        actionItems: [
            MeetingActionItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                title: "実装する",
                owner: "DIO",
                dueDateText: "次回"
            )
        ],
        transcriptSourceURL: sampleURL,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
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

private struct FakeAudioFileImporter: AudioFileImporting {
    let result: Result<AudioImportItem, Error>

    func importAudio(from url: URL) async throws -> AudioImportItem {
        try result.get()
    }
}

private final class RecordingAudioFileImporter: AudioFileImporting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<AudioImportItem, Error>
    private var urlValues: [URL] = []

    init(result: Result<AudioImportItem, Error>) {
        self.result = result
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urlValues
    }

    func importAudio(from url: URL) async throws -> AudioImportItem {
        lock.lock()
        urlValues.append(url)
        lock.unlock()

        return try result.get()
    }
}

private final class SequencedAudioFileImporter: AudioFileImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<AudioImportItem, Error>]
    private var urlValues: [URL] = []

    init(results: [Result<AudioImportItem, Error>]) {
        self.results = results
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urlValues
    }

    func importAudio(from url: URL) async throws -> AudioImportItem {
        lock.lock()
        urlValues.append(url)
        let result = results.isEmpty ? .failure(AudioImportError.fileNotFound) : results.removeFirst()
        lock.unlock()

        return try result.get()
    }
}

private struct FakeAudioTranscriptionService: AudioTranscriptionService {
    let events: [TranscriptionEvent]
    let error: Error?

    init(events: [TranscriptionEvent]) {
        self.events = events
        error = nil
    }

    init(error: Error) {
        events = []
        self.error = error
    }

    func transcribe(
        audioURL: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }

            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private struct FakeTranscriptSummaryService: TranscriptSummaryService {
    let result: TranscriptSummaryResult

    func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        result
    }
}
