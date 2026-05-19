import AVFoundation
import Foundation

enum RecordingLibraryStoreError: Error, Equatable, LocalizedError {
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .outputDirectoryUnavailable(message):
            return message
        }
    }
}

protocol RecordingLibraryStoring: Sendable {
    func recordings() async throws -> [RecordingLibraryItem]
}

struct OutputDirectoryRecordingLibraryStore: RecordingLibraryStoring {
    let outputDirectoryURL: URL

    private let fileManager: FileManager
    private let durationProvider: RecordingDurationProviding

    init(
        outputDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("meet-log", isDirectory: true),
        fileManager: FileManager = .default,
        durationProvider: RecordingDurationProviding = AVRecordingDurationProvider()
    ) {
        self.outputDirectoryURL = outputDirectoryURL
        self.fileManager = fileManager
        self.durationProvider = durationProvider
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        try scan()
    }

    private func scan() throws -> [RecordingLibraryItem] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputDirectoryURL.path, isDirectory: &isDirectory) else {
            return []
        }

        guard isDirectory.boolValue else {
            throw RecordingLibraryStoreError.outputDirectoryUnavailable("The recording output path is not a folder.")
        }

        let fileURLs: [URL]
        do {
            fileURLs = try fileManager.contentsOfDirectory(
                at: outputDirectoryURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecordingLibraryStoreError.outputDirectoryUnavailable(error.localizedDescription)
        }

        let fileNames = Set(fileURLs.map(\.lastPathComponent))
        return fileURLs
            .compactMap { url in
                RecordingLibraryItem(
                    mixdownURL: url,
                    directoryContents: fileNames,
                    fileManager: fileManager,
                    durationProvider: durationProvider
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.title < rhs.title
                }

                return lhs.createdAt > rhs.createdAt
            }
    }
}

struct FakeRecordingLibraryStore: RecordingLibraryStoring {
    var result: Result<[RecordingLibraryItem], Error>

    init(items: [RecordingLibraryItem]) {
        result = .success(items)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func recordings() async throws -> [RecordingLibraryItem] {
        try result.get()
    }
}

struct AVRecordingDurationProvider: RecordingDurationProviding {
    func duration(for url: URL) -> Duration? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)

        guard seconds.isFinite, seconds > 0 else {
            return nil
        }

        return .seconds(Int64(seconds.rounded(.down)))
            + .nanoseconds(Int64((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000_000).rounded()))
    }
}
