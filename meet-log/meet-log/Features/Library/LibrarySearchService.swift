import Foundation

enum LibrarySearchSection: String, CaseIterable, Equatable, Sendable {
    case recording
    case summary
    case transcript
    case notes

    var title: String {
        switch self {
        case .recording:
            return "録音名"
        case .summary:
            return "要約"
        case .transcript:
            return "文字起こし"
        case .notes:
            return "メモ"
        }
    }

    var systemImage: String {
        switch self {
        case .recording:
            return "waveform"
        case .summary:
            return "text.badge.checkmark"
        case .transcript:
            return "text.quote"
        case .notes:
            return "note.text"
        }
    }
}

struct LibrarySearchSnippet: Equatable, Sendable {
    let prefix: String
    let match: String
    let suffix: String
}

struct LibrarySearchMatch: Equatable, Sendable {
    let section: LibrarySearchSection
    let snippet: LibrarySearchSnippet
}

struct LibrarySearchResult: Equatable, Identifiable, Sendable {
    let item: RecordingLibraryItem
    let matches: [LibrarySearchMatch]

    var id: RecordingLibraryItem.ID {
        item.id
    }
}

struct LibrarySearchProgress: Equatable, Sendable {
    let results: [LibrarySearchResult]
    let scannedCount: Int
    let totalCount: Int
    let unprocessedCount: Int
    let isComplete: Bool
}

protocol RecordingNoteLoading: Sendable {
    func notes(for item: RecordingLibraryItem) throws -> [RecordingNote]
}

struct SidecarRecordingNoteLoader: RecordingNoteLoading {
    func notes(for item: RecordingLibraryItem) throws -> [RecordingNote] {
        let store = RecordingNoteStore()
        guard let url = store.url(for: item.mixdownURL) else {
            return []
        }
        return try store.load(from: url)
    }
}

struct LibrarySearchService: Sendable {
    private let summaryStore: MeetingSummaryStoring
    private let noteLoader: RecordingNoteLoading

    init(
        summaryStore: MeetingSummaryStoring = MeetingSummarySidecarStore(),
        noteLoader: RecordingNoteLoading = SidecarRecordingNoteLoader()
    ) {
        self.summaryStore = summaryStore
        self.noteLoader = noteLoader
    }

    func search(
        query: String,
        items: [RecordingLibraryItem]
    ) -> AsyncStream<LibrarySearchProgress> {
        let normalizedQuery = SearchText.normalized(query)
        guard !normalizedQuery.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield(
                    LibrarySearchProgress(
                        results: [],
                        scannedCount: 0,
                        totalCount: items.count,
                        unprocessedCount: 0,
                        isComplete: true
                    )
                )
                continuation.finish()
            }
        }

        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var results = [LibrarySearchResult]()
                var unprocessedCount = 0

                for (index, item) in items.enumerated() {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    let summary = try? await summaryStore.summary(for: item)
                    let transcript = try? await summaryStore.transcript(for: item)
                    let notes = (try? noteLoader.notes(for: item)) ?? []

                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    if summary == nil, transcript == nil {
                        unprocessedCount += 1
                    }

                    let matches = Self.matches(
                        query: normalizedQuery,
                        item: item,
                        summary: summary,
                        transcript: transcript,
                        notes: notes
                    )
                    if !matches.isEmpty {
                        results.append(LibrarySearchResult(item: item, matches: matches))
                    }

                    continuation.yield(
                        LibrarySearchProgress(
                            results: results,
                            scannedCount: index + 1,
                            totalCount: items.count,
                            unprocessedCount: unprocessedCount,
                            isComplete: index + 1 == items.count
                        )
                    )
                }

                if items.isEmpty {
                    continuation.yield(
                        LibrarySearchProgress(
                            results: [],
                            scannedCount: 0,
                            totalCount: 0,
                            unprocessedCount: 0,
                            isComplete: true
                        )
                    )
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func matches(
        query: String,
        item: RecordingLibraryItem,
        summary: MeetingSummary?,
        transcript: TranscriptResult?,
        notes: [RecordingNote]
    ) -> [LibrarySearchMatch] {
        var matches = [LibrarySearchMatch]()

        appendMatch(section: .recording, text: item.title, query: query, to: &matches)

        if let summary {
            let text = [
                summary.summary,
                summary.topics.flatMap { [$0.title, $0.detail].compactMap { $0 } }.joined(separator: "\n"),
                summary.actionItems.flatMap { [$0.title, $0.owner, $0.dueDateText].compactMap { $0 } }
                    .joined(separator: "\n")
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            appendMatch(section: .summary, text: text, query: query, to: &matches)
        }

        if let transcript {
            appendMatch(section: .transcript, text: transcript.summaryInputText, query: query, to: &matches)
        }

        let noteText = notes.map(\.text).joined(separator: "\n")
        if !noteText.isEmpty {
            appendMatch(section: .notes, text: noteText, query: query, to: &matches)
        }

        return matches
    }

    private static func appendMatch(
        section: LibrarySearchSection,
        text: String,
        query: String,
        to matches: inout [LibrarySearchMatch]
    ) {
        guard let snippet = SearchText.snippet(in: text, normalizedQuery: query) else {
            return
        }
        matches.append(LibrarySearchMatch(section: section, snippet: snippet))
    }
}

private enum SearchText {
    private static let contextCharacterCount = 36

    static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    static func snippet(in text: String, normalizedQuery: String) -> LibrarySearchSnippet? {
        let characters = Array(text)
        var normalizedCharacters = [Character]()
        var sourceOffsets = [Int]()

        for (offset, character) in characters.enumerated() {
            for normalizedCharacter in normalized(String(character)) {
                normalizedCharacters.append(normalizedCharacter)
                sourceOffsets.append(offset)
            }
        }

        let normalizedText = String(normalizedCharacters)
        guard let range = normalizedText.range(of: normalizedQuery) else {
            return nil
        }

        let normalizedStart = normalizedText.distance(from: normalizedText.startIndex, to: range.lowerBound)
        let normalizedEnd = normalizedText.distance(from: normalizedText.startIndex, to: range.upperBound)
        guard normalizedStart < sourceOffsets.count, normalizedEnd > normalizedStart else {
            return nil
        }

        let sourceStart = sourceOffsets[normalizedStart]
        let sourceEnd = sourceOffsets[min(normalizedEnd - 1, sourceOffsets.count - 1)] + 1
        let snippetStart = max(0, sourceStart - contextCharacterCount)
        let snippetEnd = min(characters.count, sourceEnd + contextCharacterCount)
        let leadingEllipsis = snippetStart > 0 ? "…" : ""
        let trailingEllipsis = snippetEnd < characters.count ? "…" : ""

        return LibrarySearchSnippet(
            prefix: leadingEllipsis + String(characters[snippetStart..<sourceStart]),
            match: String(characters[sourceStart..<sourceEnd]),
            suffix: String(characters[sourceEnd..<snippetEnd]) + trailingEllipsis
        )
    }
}
