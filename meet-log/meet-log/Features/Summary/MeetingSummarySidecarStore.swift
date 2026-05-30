import Foundation

protocol MeetingSummaryStoring: Sendable {
    nonisolated func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary?
    nonisolated func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws
}

struct MeetingSummarySidecarStore: MeetingSummaryStoring {
    nonisolated func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        let url = sidecarURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(MeetingSummary.self, from: data)
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    nonisolated func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {
        do {
            let url = sidecarURL(for: item)
            let data = try Self.encoder.encode(summary)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    private nonisolated func sidecarURL(for item: RecordingLibraryItem) -> URL {
        item.mixdownURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(item.id)_summary.json", isDirectory: false)
    }

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
