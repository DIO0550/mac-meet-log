import Foundation

enum SummaryServiceFactory {
    static func makeDefault() -> TranscriptSummaryService {
        #if canImport(FoundationModels) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return FoundationModelsSummaryService()
        }
        #endif

        return UnavailableSummaryService(
            reason: .foundationModelsUnavailable("Foundation Models is unavailable on this Mac.")
        )
    }
}
