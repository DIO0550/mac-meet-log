import Foundation

struct SummaryPrompt: Equatable, Sendable {
    let instructions: String
    let prompt: String
}

struct SummaryPromptBuilder: Sendable {
    static let defaultCharacterLimit = 24_000

    let characterLimit: Int

    init(characterLimit: Int = Self.defaultCharacterLimit) {
        self.characterLimit = characterLimit
    }

    nonisolated func makePrompt(for transcript: TranscriptResult) -> Result<SummaryPrompt, SummaryError> {
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return .failure(.emptyTranscript)
        }

        guard trimmedText.count <= characterLimit else {
            return .failure(.transcriptTooLong(characterCount: trimmedText.count, limit: characterLimit))
        }

        return .success(
            SummaryPrompt(
                instructions: Self.instructions,
                prompt: Self.prompt(transcriptText: trimmedText, localeIdentifier: transcript.localeIdentifier)
            )
        )
    }

    nonisolated private static let instructions = """
    あなたは日本語の会議ログ作成を支援するアシスタントです。
    文字起こしから、会議参加者が後で読み返しやすい簡潔な要約、主要トピック、アクションアイテムを抽出してください。
    推測で事実を補わず、話者や期限が不明な場合は空欄として扱ってください。
    """

    nonisolated private static func prompt(transcriptText: String, localeIdentifier: String) -> String {
        """
        次の文字起こしを会議ログとして整理してください。

        出力内容:
        - 要約: 3から6文の自然な日本語
        - 主要トピック: 議題ごとのタイトルと補足
        - アクションアイテム: タスク、担当者、期限

        locale: \(localeIdentifier)

        transcript:
        \(transcriptText)
        """
    }
}
