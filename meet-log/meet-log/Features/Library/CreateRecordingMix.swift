import Foundation

protocol RecordingLibraryMixdownServicing: Sendable {
    func export(systemAudioURL: URL?, microphoneURL: URL?, destinationURL: URL) async throws -> URL
}

@MainActor
final class CreateRecordingMix {
    struct CompletedMix {
        let recording: RecordingKey
        let directoryRevision: Int
        let duration: Duration?
    }

    nonisolated enum Failure: LocalizedError {
        case export(Error)
        case verification(Error?)

        var errorDescription: String? {
            switch self {
            case let .export(error):
                return error.localizedDescription
            case let .verification(error):
                let message = "作成したミックスを確認できませんでした。"
                guard let error else {
                    return message
                }
                return "\(message) \(error.localizedDescription)"
            }
        }
    }

    enum Update {
        case started(RecordingKey, directoryRevision: Int)
        case completed(CompletedMix)
        case failed(RecordingKey, directoryRevision: Int, Failure)
    }

    private struct Run {
        let id = UUID()
        let directoryRevision: Int
    }

    private let exporter: RecordingLibraryMixdownServicing
    private let store: RecordingLibraryStoring
    private let directoryRevision: @MainActor () -> Int
    private var running: [RecordingKey: Run] = [:]

    init(
        exporter: RecordingLibraryMixdownServicing,
        store: RecordingLibraryStoring,
        directoryRevision: @escaping @MainActor () -> Int
    ) {
        self.exporter = exporter
        self.store = store
        self.directoryRevision = directoryRevision
    }

    func start(for item: RecordingLibraryItem, onUpdate: @escaping @MainActor (Update) -> Void) {
        let recording = RecordingKey(item)
        guard item.canRemix, running[recording] == nil else {
            return
        }

        let run = Run(directoryRevision: directoryRevision())
        running[recording] = run
        let activity = LibraryActivity.begin(recording.mixdownURL)
        onUpdate(.started(recording, directoryRevision: run.directoryRevision))

        Task {
            defer {
                running[recording] = nil
                LibraryActivity.end(activity)
            }

            var didExport = false
            do {
                _ = try await exporter.export(
                    systemAudioURL: item.existingSystemAudioURL,
                    microphoneURL: item.existingMicrophoneURL,
                    destinationURL: recording.mixdownURL
                )
                didExport = true
                guard owns(run, for: recording) else {
                    return
                }

                let items = try await store.recordings()
                guard owns(run, for: recording) else {
                    return
                }
                guard let mixed = items.first(where: { RecordingKey($0) == recording && $0.hasUsableMixdown }) else {
                    onUpdate(.failed(recording, directoryRevision: run.directoryRevision, .verification(nil)))
                    return
                }

                onUpdate(.completed(CompletedMix(
                    recording: recording, directoryRevision: run.directoryRevision, duration: mixed.duration
                )))
            } catch {
                guard owns(run, for: recording) else {
                    return
                }
                let failure: Failure = didExport ? .verification(error) : .export(error)
                onUpdate(.failed(recording, directoryRevision: run.directoryRevision, failure))
            }
        }
    }

    private func owns(_ run: Run, for recording: RecordingKey) -> Bool {
        !Task.isCancelled && running[recording]?.id == run.id && directoryRevision() == run.directoryRevision
    }
}
