import Foundation

nonisolated struct TranscriptChunker: Sendable {
    let characterLimit: Int

    func split(_ text: String) throws -> [String] {
        guard characterLimit > 0 else {
            throw SummaryError.generationFailed("The summary character limit must be positive.")
        }
        guard text.count > characterLimit else {
            return [text]
        }

        let range = text.startIndex..<text.endIndex
        var sentenceEnds = Set<String.Index>()
        var wordEnds = Set<String.Index>()
        text.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            sentenceEnds.insert(enclosing.upperBound)
        }
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            wordEnds.insert(word.lowerBound)
            wordEnds.insert(word.upperBound)
        }
        for index in text.indices where text[index].isWhitespace {
            wordEnds.insert(index)
            wordEnds.insert(text.index(after: index))
            if text[index].isNewline {
                sentenceEnds.insert(text.index(after: index))
            }
        }
        let sentences = sentenceEnds.sorted()
        let words = wordEnds.sorted()
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: characterLimit, limitedBy: text.endIndex) ?? text.endIndex
            if limit == text.endIndex {
                chunks.append(String(text[start...]))
                break
            }
            let end = sentences.last { $0 > start && $0 <= limit }
                ?? words.last { $0 > start && $0 <= limit }
            guard let end else {
                // Never silently truncate or split an oversized unbroken word.
                throw SummaryError.unsplittableWord(limit: characterLimit)
            }
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
