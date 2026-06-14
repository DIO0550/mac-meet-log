import AVFoundation
import DualTrackRecorder
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
        outputDirectoryURL: URL = RecordingStorage.defaultOutputDirectoryURL,
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

        let flatItems = try sessionItems(in: outputDirectoryURL)
        let folderItems = try childDirectoryURLs(in: outputDirectoryURL)
            .flatMap { try sessionItems(in: $0) }

        return mergedItems(flatItems + folderItems)
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.title < rhs.title
                }

                return lhs.createdAt > rhs.createdAt
            }
    }

    private func sessionItems(in directoryURL: URL) throws -> [RecordingLibraryItem] {
        let fileURLs = try contentsOfDirectory(at: directoryURL)
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        let fileNames = Set(fileURLs.map(\.lastPathComponent))
        let stems = Set(fileNames.compactMap(RecordingLibraryItem.stem(fromFileName:)))

        return stems.compactMap { stem in
            RecordingLibraryItem(
                stem: stem,
                directoryURL: directoryURL,
                directoryContents: fileNames,
                fileManager: fileManager,
                durationProvider: durationProvider
            )
        }
    }

    private func childDirectoryURLs(in directoryURL: URL) throws -> [URL] {
        try contentsOfDirectory(at: directoryURL)
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    private func contentsOfDirectory(at directoryURL: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecordingLibraryStoreError.outputDirectoryUnavailable(error.localizedDescription)
        }
    }

    private func mergedItems(_ items: [RecordingLibraryItem]) -> [RecordingLibraryItem] {
        var seenIDs = Set<RecordingLibraryItem.ID>()
        var result: [RecordingLibraryItem] = []

        for item in items where !seenIDs.contains(item.id) {
            seenIDs.insert(item.id)
            result.append(item)
        }

        return result
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
