import Foundation

struct UnavailableSummaryService: TranscriptSummaryService {
    let reason: SummaryUnavailableReason

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        .unavailable(reason)
    }
}
