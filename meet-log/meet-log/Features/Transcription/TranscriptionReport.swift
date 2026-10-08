import Foundation

/// Processing coverage, independent of the editable transcript and summary text.
nonisolated struct TranscriptionReport: Codable, Equatable, Sendable {
    enum Coverage: String, Codable, Sendable {
        case complete
        case partial
        case mixdown
    }

    struct TrackIssue: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Sendable {
            case noSpeech
            case missingSource
            case processingFailed
        }

        let speaker: TranscriptSpeaker
        let reason: Reason
        let message: String?

        var description: String {
            switch reason {
            case .noSpeech:
                return "\(speaker.displayName): 認識文字なし（無音等。処理失敗とは区別しています）"
            case .missingSource:
                return "\(speaker.displayName): 素材なし（未録音または欠落）"
            case .processingFailed:
                return "\(speaker.displayName): 処理失敗 — \(message ?? "原因不明")"
            }
        }
    }

    let coverage: Coverage
    let trackIssues: [TrackIssue]
    let mixdownFailure: String?

    var warningText: String {
        let title: String
        switch coverage {
        case .complete:
            title = "認識文字のないトラックがあります。"
        case .partial:
            title = "部分的な文字起こしです。欠落トラックの発言を含まず、要約も会議全体を網羅していません。"
        case .mixdown:
            title = "mixdownで再試行した文字起こしです。入力元による自分／相手の話者区別はありません。"
        }

        var lines = [title] + trackIssues.map(\.description)
        if let mixdownFailure {
            lines.append("mixdownの再試行も失敗: \(mixdownFailure)")
        }
        return lines.joined(separator: "\n")
    }

    var summaryInstructions: String {
        """
        文字起こしの処理状況:
        \(warningText)
        欠落した発言や担当者を補完・推測しないでください。部分結果の場合は要約の冒頭にもその旨を明記してください。
        """
    }
}
