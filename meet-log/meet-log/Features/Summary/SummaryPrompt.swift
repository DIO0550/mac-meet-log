import Foundation

struct SummaryPrompt: Equatable, Sendable {
    let instructions: String
    let prompt: String
}

struct SummaryPromptBuilder: Sendable {
    nonisolated static let defaultCharacterLimit = 24_000

    let characterLimit: Int
    let template: SummaryTemplate

    nonisolated init(characterLimit: Int = Self.defaultCharacterLimit, template: SummaryTemplate = .builtIn) {
        self.characterLimit = characterLimit
        self.template = template
    }

    nonisolated func makePrompt(for transcript: TranscriptResult) -> Result<SummaryPrompt, SummaryError> {
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return .failure(.emptyTranscript)
        }

        guard trimmedText.count <= characterLimit else {
            return .failure(.transcriptTooLong(characterCount: trimmedText.count, limit: characterLimit))
        }

        let speakerInstruction = transcript.segments.contains(where: { $0.speaker != nil })
            ? "話者ラベル（自分 / 相手）を担当者推定に使い、根拠がない担当者は推測しないでください。\n"
            : ""

        return .success(
            SummaryPrompt(
                instructions: template.instructions + "\n" + speakerInstruction,
                prompt: Self.prompt(
                    transcriptText: trimmedText,
                    localeIdentifier: transcript.localeIdentifier,
                    outputPerspective: template.outputPerspective
                )
            )
        )
    }

    nonisolated private static func prompt(
        transcriptText: String,
        localeIdentifier: String,
        outputPerspective: String
    ) -> String {
        """
        次の文字起こしを会議ログとして整理してください。

        出力内容:
        \(outputPerspective)

        locale: \(localeIdentifier)

        transcript:
        \(transcriptText)
        """
    }
}
