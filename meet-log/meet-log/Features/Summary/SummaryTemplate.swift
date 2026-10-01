import Foundation

nonisolated struct SummaryTemplate: Codable, Equatable, Identifiable, Sendable {
    static let builtIn = SummaryTemplate(
        id: "meeting",
        name: "会議ログ（標準）",
        instructions: """
        あなたは日本語の会議ログ作成を支援するアシスタントです。
        文字起こしから、会議参加者が後で読み返しやすい簡潔な要約、主要トピック、アクションアイテムを抽出してください。
        推測で事実を補わず、話者や期限が不明な場合は空欄として扱ってください。
        """,
        outputPerspective: """
        - 要約: 3から6文の自然な日本語
        - 主要トピック: 議題ごとのタイトルと補足
        - アクションアイテム: タスク、担当者、期限
        """,
        isBuiltIn: true
    )

    let id: String
    var name: String
    var instructions: String
    var outputPerspective: String
    let isBuiltIn: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        outputPerspective: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.outputPerspective = outputPerspective
        self.isBuiltIn = isBuiltIn
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !outputPerspective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func duplicate() -> SummaryTemplate {
        SummaryTemplate(
            name: "\(name) のコピー",
            instructions: instructions,
            outputPerspective: outputPerspective
        )
    }
}

enum SummaryTemplateError: Error, Equatable, LocalizedError {
    case invalid
    case builtInCannotBeModified
    case builtInCannotBeDeleted

    var errorDescription: String? {
        switch self {
        case .invalid:
            return "名前、指示、出力観点をすべて入力してください。"
        case .builtInCannotBeModified:
            return "組み込みテンプレートは編集できません。複製して編集してください。"
        case .builtInCannotBeDeleted:
            return "組み込みテンプレートは削除できません。"
        }
    }
}
