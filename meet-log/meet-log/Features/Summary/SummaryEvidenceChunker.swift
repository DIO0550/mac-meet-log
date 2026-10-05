import Foundation

nonisolated struct SummaryEvidenceChunk: Sendable {
    let text: String
    let screen: Bool
    let evidenceIDs: Set<String>
}

nonisolated struct SummaryEvidenceChunker {
    let characterLimit: Int

    func split(_ transcript: TranscriptResult) throws -> [SummaryEvidenceChunk] {
        let catalog = SummaryEvidenceCatalog(transcript)
        let audio = catalog.audioInput
        let screen = catalog.screenInput
        var chunks: [SummaryEvidenceChunk] = []
        if audio.isEmpty {
            chunks += try plainChunks(transcript.text, screen: false)
        }
        chunks += try timedChunks(audio)
        if screen.isEmpty {
            chunks += try plainChunks(transcript.screenText, screen: true)
            return chunks
        }
        return chunks + (try timedChunks(screen))
    }

    private func plainChunks(_ text: String, screen: Bool) throws -> [SummaryEvidenceChunk] {
        try TranscriptChunker(characterLimit: characterLimit).split(text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { SummaryEvidenceChunk(text: $0, screen: screen, evidenceIDs: []) }
    }

    private func timedChunks(_ entries: [SummaryEvidenceInput]) throws -> [SummaryEvidenceChunk] {
        var chunks: [SummaryEvidenceChunk] = []
        var lines: [String] = []
        var ids = Set<String>()
        var length = 0
        for entry in entries {
            let label = entry.label
            let parts = try TranscriptChunker(characterLimit: characterLimit - label.count).split(entry.text)
            for part in parts {
                let line = label + part
                if !lines.isEmpty, length + 1 + line.count > characterLimit {
                    chunks.append(SummaryEvidenceChunk(text: lines.joined(separator: "\n"),
                                                       screen: entry.screen, evidenceIDs: ids))
                    lines = []
                    ids = []
                    length = 0
                }
                if !lines.isEmpty {
                    length += 1
                }
                lines.append(line)
                if let evidence = entry.evidence {
                    ids.insert(evidence.id)
                }
                length += line.count
            }
        }
        if let entry = entries.first, !lines.isEmpty {
            chunks.append(SummaryEvidenceChunk(text: lines.joined(separator: "\n"),
                                               screen: entry.screen, evidenceIDs: ids))
        }
        return chunks
    }
}
