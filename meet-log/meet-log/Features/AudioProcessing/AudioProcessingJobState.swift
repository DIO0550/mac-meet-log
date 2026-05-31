import Foundation

nonisolated enum AudioProcessingJobState: Equatable, Sendable {
    case idle
    case loading
    case transcribing(AudioImportItem, partialTranscript: String?)
    case summarizing(AudioImportItem, TranscriptResult)
    case completed(AudioImportItem, TranscriptResult, TranscriptSummaryResult)
    case failed(AudioImportItem?, AudioProcessingError, transcript: TranscriptResult?)
    case cancelled(AudioImportItem?)

    var importedItem: AudioImportItem? {
        switch self {
        case .idle, .loading:
            return nil
        case let .transcribing(item, _),
             let .summarizing(item, _),
             let .completed(item, _, _):
            return item
        case let .failed(item, _, _),
             let .cancelled(item):
            return item
        }
    }

    var transcript: TranscriptResult? {
        switch self {
        case let .summarizing(_, transcript),
             let .completed(_, transcript, _):
            return transcript
        case let .failed(_, _, transcript):
            return transcript
        case .idle, .loading, .transcribing, .cancelled:
            return nil
        }
    }
}

nonisolated enum AudioProcessingError: Error, Equatable, LocalizedError, Sendable {
    case importFailed(AudioImportError)
    case transcriptionFailed(TranscriptionError)
    case summaryFailed(SummaryError)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case let .importFailed(error):
            return error.localizedDescription
        case let .transcriptionFailed(error):
            return error.localizedDescription
        case let .summaryFailed(error):
            return error.localizedDescription
        case let .unexpected(message):
            return message
        }
    }
}
