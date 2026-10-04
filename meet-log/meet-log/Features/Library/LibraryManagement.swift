import DualTrackRecorder
import Foundation

struct RecordingDisplayMetadata: Codable, Equatable, Sendable {
    var name: String
    var tags: [String]
    var createdAt: Date
    var screenRemoved = false

    init(name: String, tags: [String], createdAt: Date, screenRemoved: Bool = false) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        self.createdAt = createdAt
        self.screenRemoved = screenRemoved
    }
}

/// Display metadata never changes the media stem or the identity used by existing sidecars.
struct RecordingDisplayMetadataStore {
    func url(for item: RecordingLibraryItem) -> URL {
        item.sessionDirectoryURL.appendingPathComponent("\(item.storageStem)_library.json")
    }

    func load(stem: String, directory: URL) throws -> RecordingDisplayMetadata? {
        let url = directory.appendingPathComponent("\(stem)_library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try LibraryFileSafety.validate(url, in: directory)
        return try JSONDecoder().decode(RecordingDisplayMetadata.self, from: Data(contentsOf: url))
    }

    func save(_ metadata: RecordingDisplayMetadata, for item: RecordingLibraryItem) throws {
        let destination = url(for: item)
        try LibraryFileSafety.validate(destination, in: item.sessionDirectoryURL)
        try JSONEncoder().encode(metadata).write(to: destination, options: .atomic)
    }
}

enum LibraryManagementError: LocalizedError {
    case busy, unsafeFile, changed
    var errorDescription: String? {
        switch self {
        case .busy: return "録音・処理・編集・再生中です。終了してから操作してください。"
        case .unsafeFile: return "関連ファイルの安全性を確認できません。リンクやフォルダを確認してください。"
        case .changed: return "対象ファイルが変更されています。確認画面を開き直してください。"
        }
    }
}

/// Main-actor activity tracking spans Library windows, including cancelled tasks until they exit.
@MainActor
enum LibraryActivity {
    private static var active: [UUID: URL] = [:]
    static func begin(_ url: URL) -> UUID {
        let id = UUID()
        active[id] = url.resolvingSymlinksInPath().standardizedFileURL
        return id
    }
    static func end(_ id: UUID?) {
        guard let id else { return }
        active[id] = nil
    }
    static func isBusy(_ url: URL) -> Bool {
        active.values.contains(url.resolvingSymlinksInPath().standardizedFileURL)
    }
}

enum LibraryFileSafety {
    static func validate(_ url: URL, in directory: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw LibraryManagementError.unsafeFile
        }
        // lstat-style attributes reject symlinks (including dangling links) and directories.
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw LibraryManagementError.unsafeFile
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
    }
}

enum LibraryTrashScope: String, CaseIterable, Identifiable {
    case screen, all
    var id: String { rawValue }
    var title: String { self == .screen ? "画面動画のみ" : "録音一式" }
    var explanation: String {
        self == .screen
            ? "音声・議事録・メモ・保存済みOCRは残します。動画再生と再OCRは利用できなくなります。"
            : "音声・画面動画・議事録・文字起こし（OCRを含む）・メモ・表示名とタグをゴミ箱へ移動します。"
    }
}

struct LibraryTrashFile: Equatable, Identifiable {
    let url: URL
    let byteCount: Int64
    let modifiedAt: Date?
    var id: URL { url }
}

struct LibraryTrashPlan: Identifiable {
    let id = UUID()
    let item: RecordingLibraryItem
    let scope: LibraryTrashScope
    let files: [LibraryTrashFile]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

struct LibraryTrashResult {
    var moved: [URL] = []
    var failures: [String] = []
    var message: String {
        (["\(moved.count) 件をゴミ箱へ移動しました。"] + failures).joined(separator: "\n")
    }
}

struct LibraryTrashService {
    var trash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func plan(for item: RecordingLibraryItem, scope: LibraryTrashScope) throws -> LibraryTrashPlan {
        let files = try candidates(for: item, scope: scope).compactMap { url -> LibraryTrashFile? in
            try LibraryFileSafety.validate(url, in: url.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return LibraryTrashFile(url: url, byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                    modifiedAt: attributes[.modificationDate] as? Date)
        }
        return LibraryTrashPlan(item: item, scope: scope, files: files)
    }

    func execute(_ plan: LibraryTrashPlan) throws -> LibraryTrashResult {
        guard !LibraryActivity.isBusy(plan.item.mixdownURL) else { throw LibraryManagementError.busy }
        let leases = try lockedDirectories(for: plan.item).map { try RecordingSessionLease(directory: $0) }
        defer { withExtendedLifetime(leases) {} }
        let current = try self.plan(for: plan.item, scope: plan.scope)
        // Newly added/replaced files require a new confirmation; disappeared files are reported below.
        guard current.files.allSatisfy({ plan.files.contains($0) }) else { throw LibraryManagementError.changed }
        if plan.scope == .screen, !current.files.isEmpty {
            var metadata = try RecordingDisplayMetadataStore().load(stem: plan.item.storageStem, directory: plan.item.sessionDirectoryURL)
                ?? RecordingDisplayMetadata(name: plan.item.title, tags: plan.item.tags, createdAt: plan.item.createdAt)
            metadata.screenRemoved = true
            try RecordingDisplayMetadataStore().save(metadata, for: plan.item)
        }
        var result = LibraryTrashResult()
        for file in plan.files {
            // Keep metadata discoverable if any preceding media/sidecar move failed.
            if file.url == RecordingDisplayMetadataStore().url(for: plan.item), !result.failures.isEmpty {
                result.failures.append("\(file.url.lastPathComponent): 部分失敗のため表示情報を保持しました。")
                continue
            }
            do {
                try LibraryFileSafety.validate(file.url, in: file.url.deletingLastPathComponent())
                guard FileManager.default.fileExists(atPath: file.url.path) else { throw CocoaError(.fileNoSuchFile) }
                try trash(file.url)
                result.moved.append(file.url)
            } catch {
                result.failures.append("\(file.url.path): \(error.localizedDescription)")
            }
        }
        if !result.failures.isEmpty, !FileManager.default.fileExists(atPath: RecordingDisplayMetadataStore().url(for: plan.item).path) {
            do {
                try RecordingDisplayMetadataStore().save(
                    RecordingDisplayMetadata(name: plan.item.title, tags: plan.item.tags, createdAt: plan.item.createdAt),
                    for: plan.item
                )
            } catch { result.failures.append("表示情報の保持に失敗しました: \(error.localizedDescription)") }
        }
        return result
    }

    func saveMetadata(_ metadata: RecordingDisplayMetadata, for item: RecordingLibraryItem) throws {
        guard !LibraryActivity.isBusy(item.mixdownURL) else { throw LibraryManagementError.busy }
        let leases = try lockedDirectories(for: item).map { try RecordingSessionLease(directory: $0) }
        defer { withExtendedLifetime(leases) {} }
        guard try !plan(for: item, scope: .all).files.isEmpty else { throw LibraryManagementError.changed }
        try RecordingDisplayMetadataStore().save(metadata, for: item)
    }

    private func lockedDirectories(for item: RecordingLibraryItem) -> [URL] {
        guard let original = recoveryOriginalDirectory(for: item) else { return [item.sessionDirectoryURL] }
        return [original, item.sessionDirectoryURL]
    }

    private func recoveryOriginalDirectory(for item: RecordingLibraryItem) -> URL? {
        let parent = item.sessionDirectoryURL.deletingLastPathComponent()
        guard item.sessionDirectoryURL.lastPathComponent == "recovered",
              let report = try? RecordingRecoveryStore.loadReport(in: item.sessionDirectoryURL),
              let journal = try? RecordingJournal.load(in: parent),
              report.sessionID == journal.id, journal.stem == item.storageStem else { return nil }
        return parent
    }

    private func candidates(for item: RecordingLibraryItem, scope: LibraryTrashScope) throws -> [URL] {
        let directory = item.sessionDirectoryURL
        let stem = item.storageStem
        guard !stem.isEmpty, !item.id.contains("/"), !item.id.contains("\\") else { throw LibraryManagementError.unsafeFile }
        let directories = [directory] + (recoveryOriginalDirectory(for: item).map { [$0] } ?? [])
        if scope == .screen { return directories.map { $0.appendingPathComponent("\(stem)_screen.mp4") } }
        // Exact names only: no prefix glob and no recursive deletion of a session folder.
        let names = RecordingLibraryItem.TrackKind.allCases.map { "\(stem)_\($0.rawValue).\($0.fileExtension)" }
            + ["\(item.id)_summary.md", "\(item.id)_transcript.md", "\(stem)_notes.json"]
        var urls = directories.flatMap { directory in names.map { directory.appendingPathComponent($0) } }
        for directory in directories {
            for kind in ["system", "microphone"] {
                let segments = directory.appendingPathComponent("\(stem)_\(kind).segments")
                guard FileManager.default.fileExists(atPath: segments.path) else { continue }
                guard try FileManager.default.attributesOfItem(atPath: segments.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw LibraryManagementError.unsafeFile
                }
                let children = try FileManager.default.contentsOfDirectory(at: segments, includingPropertiesForKeys: nil)
                urls += children.filter {
                    $0.lastPathComponent.range(of: #"^([0-9]{20}-[0-9]{20}|[0-9A-Fa-f-]{36}\.partial)\.m4a$"#,
                                              options: .regularExpression) != nil
                }.sorted { $0.path < $1.path }
            }
        }
        // Leave checkpoint/lock/recovery-report files in place: they preserve provenance and
        // prevent a trashed recovered session from being offered for recovery again.
        return urls + [RecordingDisplayMetadataStore().url(for: item)]
    }
}
