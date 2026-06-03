import Foundation

enum SummaryServiceFactory {
    nonisolated static func makeDefault() -> TranscriptSummaryService {
        #if canImport(FoundationModels) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return FallbackTranscriptSummaryService(
                primary: FoundationModelsSummaryService(),
                fallback: ExtractiveTranscriptSummaryService()
            )
        }
        #endif

        return ExtractiveTranscriptSummaryService()
    }
}
