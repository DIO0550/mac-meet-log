import Combine
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case empty
        case loaded([RecordingLibraryItem])
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published var selectedID: RecordingLibraryItem.ID?
    @Published private(set) var playbackState: MixdownPlaybackController.State = .stopped

    private let store: RecordingLibraryStoring
    private lazy var playbackController = MixdownPlaybackController { [weak self] state in
        self?.playbackState = state
    }

    convenience init() {
        self.init(store: OutputDirectoryRecordingLibraryStore())
    }

    init(store: RecordingLibraryStoring) {
        self.store = store
    }

    var items: [RecordingLibraryItem] {
        guard case let .loaded(items) = state else {
            return []
        }

        return items
    }

    var selectedItem: RecordingLibraryItem? {
        guard !items.isEmpty else {
            return nil
        }

        if let selectedID, let item = items.first(where: { $0.id == selectedID }) {
            return item
        }

        return items.first
    }

    var isPlayingSelectedItem: Bool {
        guard let selectedItem else {
            return false
        }

        return playbackState == .playing(selectedItem.mixdownURL)
    }

    func load() async {
        await refresh(shouldShowLoading: true)
    }

    func refresh() {
        Task {
            await refresh(shouldShowLoading: false)
        }
    }

    func select(_ item: RecordingLibraryItem) {
        selectedID = item.id
    }

    func togglePlayback() {
        guard let selectedItem else {
            return
        }

        playbackController.toggle(url: selectedItem.mixdownURL)
    }

    func stopPlayback() {
        playbackController.stop()
    }

    func revealSelectedItemInFinder() {
        guard let selectedItem else {
            return
        }

        LibraryFinder.reveal(fileURL: selectedItem.mixdownURL)
    }

    private func refresh(shouldShowLoading: Bool) async {
        if shouldShowLoading {
            state = .loading
        }

        do {
            let loadedItems = try await store.recordings()
            reconcileSelection(with: loadedItems)
            state = loadedItems.isEmpty ? .empty : .loaded(loadedItems)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func reconcileSelection(with loadedItems: [RecordingLibraryItem]) {
        guard !loadedItems.isEmpty else {
            selectedID = nil
            return
        }

        if let selectedID, loadedItems.contains(where: { $0.id == selectedID }) {
            return
        }

        selectedID = loadedItems.first?.id
    }
}
