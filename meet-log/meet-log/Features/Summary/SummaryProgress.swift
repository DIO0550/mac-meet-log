import Foundation

nonisolated enum SummaryProgress: Equatable, Sendable {
    case chunk(completed: Int, total: Int)
    case integration(round: Int, completed: Int, total: Int)

    var message: String {
        switch self {
        case let .chunk(completed, total):
            return "分割要約: \(completed) / \(total) チャンク完了"
        case let .integration(round, completed, total):
            return "要約の統合 (\(round)段階目): \(completed) / \(total) 完了"
        }
    }
}

typealias SummaryProgressHandler = @Sendable (SummaryProgress) async -> Void
