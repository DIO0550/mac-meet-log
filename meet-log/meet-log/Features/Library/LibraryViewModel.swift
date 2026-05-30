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

    enum SummaryState: Equatable {
        case idle
        case loadingSaved
        case transcribing
        case summarizing
        case summarized(MeetingSummary)
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published var selectedID: RecordingLibraryItem.ID? {
        didSet {
            guard selectedID != oldValue else {
                return
            }

            loadSummaryForSelectedItem()
        }
    }
    @Published private(set) var playbackState: MixdownPlaybackController.State = .stopped
    @Published private(set) var summaryState: SummaryState = .idle

    private let store: RecordingLibraryStoring
    private let transcriptionService: AudioTranscriptionService
    private let summaryService: TranscriptSummaryService
    private let summaryStore: MeetingSummaryStoring
    private lazy var playbackController = MixdownPlaybackController { [weak self] state in
        self?.playbackState = state
    }

    convenience init() {
        self.init(
            store: OutputDirectoryRecordingLibraryStore(),
            transcriptionService: LegacySpeechTranscriptionService(),
            summaryService: SummaryServiceFactory.makeDefault(),
            summaryStore: MeetingSummarySidecarStore()
        )
    }

    convenience init(store: RecordingLibraryStoring) {
        self.init(
            store: store,
            transcriptionService: LegacySpeechTranscriptionService(),
            summaryService: UnavailableSummaryService(
                reason: .foundationModelsUnavailable("Foundation Models is unavailable on this Mac.")
            ),
            summaryStore: MeetingSummarySidecarStore()
        )
    }

    init(
        store: RecordingLibraryStoring,
        transcriptionService: AudioTranscriptionService,
        summaryService: TranscriptSummaryService,
        summaryStore: MeetingSummaryStoring
    ) {
        self.store = store
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.summaryStore = summaryStore
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

    var isSummaryBusy: Bool {
        switch summaryState {
        case .loadingSaved, .transcribing, .summarizing:
            return true
        case .idle, .summarized, .unavailable, .failed:
            return false
        }
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

    func loadSummaryForSelectedItem() {
        guard let selectedItem else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        summaryState = .loadingSaved

        Task {
            do {
                if let summary = try await summaryStore.summary(for: item) {
                    summaryState = .summarized(summary)
                } else {
                    summaryState = .idle
                }
            } catch {
                summaryState = .failed(error.localizedDescription)
            }
        }
    }

    func generateSummaryForSelectedItem() {
        guard let selectedItem else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        summaryState = .transcribing

        Task {
            do {
                let transcript = try await transcriptionService.finalTranscript(audioURL: item.mixdownURL)
                summaryState = .summarizing
                await handleSummaryResult(await summaryService.summarize(transcript), for: item)
            } catch {
                summaryState = .failed(error.localizedDescription)
            }
        }
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
            loadSummaryForSelectedItem()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func handleSummaryResult(_ result: TranscriptSummaryResult, for item: RecordingLibraryItem) async {
        switch result {
        case let .summarized(summary):
            do {
                try await summaryStore.save(summary, for: item)
                summaryState = .summarized(summary)
            } catch {
                summaryState = .failed(error.localizedDescription)
            }
        case let .unavailable(reason):
            summaryState = .unavailable(reason.localizedDescription)
        case let .failed(error):
            summaryState = .failed(error.localizedDescription)
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
