import Foundation

enum TranscriptionEvent: Equatable, Sendable {
    case partial(String)
    case completed(TranscriptResult)
}
