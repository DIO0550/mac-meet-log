import Combine
import Foundation

@MainActor
final class AudioImportViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case importing
        case imported(AudioImportItem)
        case failed(AudioImportError)
    }

    @Published private(set) var state: State = .idle
    @Published var isImporterPresented = false

    private let importer: AudioFileImporting

    init(importer: AudioFileImporting = AVAudioFileImporter()) {
        self.importer = importer
    }

    func presentImporter() {
        isImporterPresented = true
    }

    func handleImporterResult(_ result: Result<URL, Error>) {
        isImporterPresented = false

        switch result {
        case let .success(url):
            importAudio(from: url)
        case let .failure(error):
            if (error as NSError).code == NSUserCancelledError {
                state = .idle
                return
            }

            state = .failed(.unreadable(error.localizedDescription))
        }
    }

    func clear() {
        state = .idle
    }

    private func importAudio(from url: URL) {
        state = .importing

        Task {
            do {
                state = .imported(try await importer.importAudio(from: url))
            } catch let error as AudioImportError {
                state = .failed(error)
            } catch {
                state = .failed(.unreadable(error.localizedDescription))
            }
        }
    }
}
