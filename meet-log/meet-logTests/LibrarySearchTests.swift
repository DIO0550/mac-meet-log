import Foundation
import Testing
@testable import meet_log

struct LibrarySearchTests {
    @Test func searchesEverySectionIgnoringCaseWidthAndKanaDifferences() async throws {
        let item = makeItem(id: "meeting", title: "かいぎログ")
        let summary = MeetingSummary(
            summary: "カイギの要点です。",
            topics: [],
            actionItems: [],
            transcriptSourceURL: item.mixdownURL
        )
        let transcript = TranscriptResult(
            text: "ｶｲｷﾞを始めます。",
            localeIdentifier: "ja-JP",
            sourceURL: item.mixdownURL
        )
        let service = LibrarySearchService(
            summaryStore: SearchFakeSummaryStore(
                summaries: [item.id: summary],
                transcripts: [item.id: transcript]
            ),
            noteLoader: SearchFakeNoteLoader(notes: [
                item.id: [RecordingNote(elapsed: 5, text: "次のかいぎを確認する")]
            ])
        )

        let progress = await finalProgress(from: service.search(query: "カイギ", items: [item]))
        let result = try #require(progress?.results.first)

        #expect(result.matches.map(\.section) == [.recording, .summary, .transcript, .notes])
        #expect(result.matches[0].snippet.match == "かいぎ")
        #expect(result.matches[1].snippet.match == "カイギ")
        #expect(result.matches[2].snippet.match == "ｶｲｷﾞ")
        #expect(result.matches[3].snippet.match == "かいぎ")
        #expect(progress?.isComplete == true)
    }

    @Test func reportsRecordingWithoutSearchableSidecars() async {
        let item = makeItem(id: "unprocessed", title: "定例")
        let service = LibrarySearchService(
            summaryStore: SearchFakeSummaryStore(),
            noteLoader: SearchFakeNoteLoader()
        )

        let progress = await finalProgress(from: service.search(query: "見つからない", items: [item]))

        #expect(progress?.results.isEmpty == true)
        #expect(progress?.unprocessedCount == 1)
        #expect(progress?.scannedCount == 1)
        #expect(progress?.isComplete == true)
    }

    @Test func cancellingConsumerStopsLargeSearch() async throws {
        let items = (0..<100).map { makeItem(id: "item-\($0)", title: "録音 \($0)") }
        let store = SlowSearchSummaryStore()
        let service = LibrarySearchService(
            summaryStore: store,
            noteLoader: SearchFakeNoteLoader()
        )
        let stream = service.search(query: "一致なし", items: items)
        let consumer = Task {
            for await _ in stream {}
        }

        try await Task.sleep(for: .milliseconds(45))
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.callCount > 0)
        #expect(store.callCount < items.count * 2)
    }

    private func finalProgress(
        from stream: AsyncStream<LibrarySearchProgress>
    ) async -> LibrarySearchProgress? {
        var finalProgress: LibrarySearchProgress?
        for await progress in stream {
            finalProgress = progress
        }
        return finalProgress
    }

    private func makeItem(id: String, title: String) -> RecordingLibraryItem {
        let directoryURL = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        return RecordingLibraryItem(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 0),
            duration: .seconds(60),
            mixdownURL: directoryURL.appendingPathComponent("\(id)_mix.m4a"),
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

private struct SearchFakeSummaryStore: MeetingSummaryStoring {
    let summaries: [String: MeetingSummary]
    let transcripts: [String: TranscriptResult]

    init(
        summaries: [String: MeetingSummary] = [:],
        transcripts: [String: TranscriptResult] = [:]
    ) {
        self.summaries = summaries
        self.transcripts = transcripts
    }

    func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        summaries[item.id]
    }

    func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? {
        transcripts[item.id]
    }

    func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {}

    func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {}
}

private struct SearchFakeNoteLoader: RecordingNoteLoading {
    let notes: [String: [RecordingNote]]

    init(notes: [String: [RecordingNote]] = [:]) {
        self.notes = notes
    }

    func notes(for item: RecordingLibraryItem) throws -> [RecordingNote] {
        notes[item.id] ?? []
    }
}

private final class SlowSearchSummaryStore: MeetingSummaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callCountValue = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountValue
    }

    func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        recordCall()
        try await Task.sleep(for: .milliseconds(20))
        return nil
    }

    func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? {
        recordCall()
        try await Task.sleep(for: .milliseconds(20))
        return nil
    }

    func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {}

    func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {}

    private func recordCall() {
        lock.lock()
        callCountValue += 1
        lock.unlock()
    }
}
