import Foundation

nonisolated enum LibraryProcessingStage: String, CaseIterable, Identifiable, Sendable {
    case transcription
    case screenOCR
    case summary
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .transcription: return "文字起こしを再実行"
        case .screenOCR: return "画面OCRを再実行"
        case .summary: return "保存済みテキストから要約を再生成"
        case .all: return "すべての工程を実行"
        }
    }

    @MainActor var initialState: LibraryViewModel.SummaryState {
        switch self {
        case .transcription, .all: return .transcribing
        case .screenOCR: return .recognizingScreen
        case .summary: return .summarizing
        }
    }
}
