import Combine
import DualTrackRecorder
import Foundation

struct AppPreferences: Codable, Equatable {
    var systemAudioEnabled = true
    var microphoneEnabled = true
    var microphoneDeviceUID: String?
    var localeIdentifier = "ja-JP"
    var summaryTemplateID = "meeting"
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let preferencesKey = "preferences.v1"
    static let directoryBookmarkKey = "recordings.directory.bookmark"
    static let recoveryBookmarksKey = "recordings.recovery.bookmarks"
    static let summaryTemplatesKey = "summary.templates.v1"

    @Published var preferences: AppPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: Self.preferencesKey)
            }
        }
    }
    @Published private(set) var directoryRevision = 0
    @Published private(set) var summaryTemplates: [SummaryTemplate]
    private let defaults: UserDefaults
    // Keep old scopes alive for recordings, playback and sidecar writes already in flight.
    private var directoryAccess: [URL: SecurityScopedDirectory] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = AppPreferences()
        }
        let savedTemplates = defaults.data(forKey: Self.summaryTemplatesKey)
            .flatMap { try? JSONDecoder().decode([SummaryTemplate].self, from: $0) } ?? []
        summaryTemplates = [.builtIn] + savedTemplates.filter {
            !$0.isBuiltIn && $0.id != SummaryTemplate.builtIn.id && $0.isValid
        }
        if !summaryTemplates.contains(where: { $0.id == preferences.summaryTemplateID }) {
            preferences.summaryTemplateID = SummaryTemplate.builtIn.id
        }
    }

    func resolveOutputDirectory() throws -> URL {
        guard let bookmark = defaults.data(forKey: Self.directoryBookmarkKey) else {
            return RecordingStorage.defaultOutputDirectoryURL
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            retainAccess(to: url)
            rememberRecoveryBookmark(bookmark)
            if stale {
                let refreshed = try makeBookmark(for: url)
                defaults.set(refreshed, forKey: Self.directoryBookmarkKey)
            }
            return url
        } catch {
            throw RecorderError.outputFailed("保存先を開けません。設定でフォルダを選び直してください。\n\(error.localizedDescription)")
        }
    }

    func selectOutputDirectory(_ url: URL) throws {
        let access = SecurityScopedDirectory(url: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw RecorderError.outputFailed("保存先にはフォルダを選択してください。")
        }
        let bookmark = try makeBookmark(for: url)
        if let previous = defaults.data(forKey: Self.directoryBookmarkKey) { rememberRecoveryBookmark(previous) }
        rememberRecoveryBookmark(bookmark)
        defaults.set(bookmark, forKey: Self.directoryBookmarkKey)
        if directoryAccess[url] == nil {
            directoryAccess[url] = access
        }
        directoryRevision += 1
    }

    func resetOutputDirectory() {
        if let previous = defaults.data(forKey: Self.directoryBookmarkKey) { rememberRecoveryBookmark(previous) }
        defaults.removeObject(forKey: Self.directoryBookmarkKey)
        directoryRevision += 1
    }

    /// Retain access to earlier destinations after a crash or an in-flight Settings change.
    func recoveryDirectories() -> (directories: [URL], warnings: [String]) {
        var directories: Set<URL> = [RecordingStorage.defaultOutputDirectoryURL]
        var warnings: [String] = []
        do { directories.insert(try resolveOutputDirectory()) }
        catch { warnings.append(error.localizedDescription) }
        for bookmark in defaults.array(forKey: Self.recoveryBookmarksKey) as? [Data] ?? [] {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
                retainAccess(to: url)
                directories.insert(url)
            } catch {
                warnings.append("以前の保存先を確認できません。ドライブを接続して設定で選び直してください。\n\(error.localizedDescription)")
            }
        }
        return (Array(directories), warnings)
    }

    private func rememberRecoveryBookmark(_ data: Data) {
        var bookmarks = defaults.array(forKey: Self.recoveryBookmarksKey) as? [Data] ?? []
        guard !bookmarks.contains(data) else { return }
        bookmarks.append(data)
        defaults.set(bookmarks, forKey: Self.recoveryBookmarksKey)
    }

    func defaultMicrophoneID(in devices: [AudioInputDevice]) -> String? {
        guard let uid = preferences.microphoneDeviceUID else {
            return nil
        }
        return devices.first { $0.persistentUID == uid }?.id
    }

    func summaryTemplate(id: String? = nil) -> SummaryTemplate {
        let requestedID = id ?? preferences.summaryTemplateID
        return summaryTemplates.first { $0.id == requestedID } ?? .builtIn
    }

    func saveSummaryTemplate(_ template: SummaryTemplate) throws {
        guard template.isValid else {
            throw SummaryTemplateError.invalid
        }
        guard !template.isBuiltIn, template.id != SummaryTemplate.builtIn.id else {
            throw SummaryTemplateError.builtInCannotBeModified
        }
        if let index = summaryTemplates.firstIndex(where: { $0.id == template.id }) {
            summaryTemplates[index] = template
        } else {
            summaryTemplates.append(template)
        }
        persistSummaryTemplates()
    }

    @discardableResult
    func duplicateSummaryTemplate(_ template: SummaryTemplate) throws -> SummaryTemplate {
        let copy = template.duplicate()
        try saveSummaryTemplate(copy)
        return copy
    }

    func deleteSummaryTemplate(id: String) throws {
        guard id != SummaryTemplate.builtIn.id else {
            throw SummaryTemplateError.builtInCannotBeDeleted
        }
        summaryTemplates.removeAll { $0.id == id }
        if preferences.summaryTemplateID == id {
            preferences.summaryTemplateID = SummaryTemplate.builtIn.id
        }
        persistSummaryTemplates()
    }

    private func persistSummaryTemplates() {
        let customTemplates = summaryTemplates.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(customTemplates) {
            defaults.set(data, forKey: Self.summaryTemplatesKey)
        }
    }

    private func retainAccess(to url: URL) {
        guard directoryAccess[url] == nil else {
            return
        }
        directoryAccess[url] = SecurityScopedDirectory(url: url)
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

private final class SecurityScopedDirectory {
    private let url: URL
    private let accessing: Bool

    init(url: URL) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class SettingsRecordingLibraryStore: RecordingLibraryStoring {
    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        let url = try settings.resolveOutputDirectory()
        var items = try await OutputDirectoryRecordingLibraryStore(outputDirectoryURL: url).recordings()
        for previous in settings.recoveryDirectories().directories where previous != url {
            let oldItems = (try? await OutputDirectoryRecordingLibraryStore(outputDirectoryURL: previous).recordings()) ?? []
            items += oldItems.filter { (try? RecordingRecoveryStore.loadReport(in: $0.sessionDirectoryURL)) != nil }
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }
}
