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

    @Published var preferences: AppPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: Self.preferencesKey)
            }
        }
    }
    @Published private(set) var directoryRevision = 0
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
        defaults.set(bookmark, forKey: Self.directoryBookmarkKey)
        if directoryAccess[url] == nil {
            directoryAccess[url] = access
        }
        directoryRevision += 1
    }

    func resetOutputDirectory() {
        defaults.removeObject(forKey: Self.directoryBookmarkKey)
        directoryRevision += 1
    }

    func defaultMicrophoneID(in devices: [AudioInputDevice]) -> String? {
        guard let uid = preferences.microphoneDeviceUID else {
            return nil
        }
        return devices.first { $0.persistentUID == uid }?.id
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
        return try await OutputDirectoryRecordingLibraryStore(outputDirectoryURL: url).recordings()
    }
}
