import Combine
import DualTrackRecorder
import Foundation

protocol RecordingLibraryMixdownServicing: Sendable {
    func export(systemAudioURL: URL?, microphoneURL: URL?, destinationURL: URL) async throws -> URL
}

extension RecordingMixdownService: RecordingLibraryMixdownServicing {}

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
        case summaryProgress(SummaryProgress)
        case summarized(MeetingSummary)
        case unavailable(String)
        case failed(String)
    }

    enum RemixState: Equatable {
        case idle
        case mixing(RecordingLibraryItem.ID)
        case failed(RecordingLibraryItem.ID, String)
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
    @Published private(set) var transcript: TranscriptResult?
    @Published private(set) var remixState: RemixState = .idle

    private let store: RecordingLibraryStoring
    private let trackAwareTranscriptionService: TrackAwareTranscriptionService
    private let summaryService: TranscriptSummaryService
    private let summaryStore: MeetingSummaryStoring
    private let mixdownService: RecordingLibraryMixdownServicing
    private lazy var playbackController = MixdownPlaybackController { [weak self] state in
        self?.playbackState = state
    }

    convenience init() {
        self.init(
            store: SettingsRecordingLibraryStore(),
            transcriptionService: TranscriptionServiceFactory.makeDefault(),
            summaryService: SummaryServiceFactory.makeDefault(),
            summaryStore: MeetingSummarySidecarStore(),
            mixdownService: RecordingMixdownService()
        )
    }

    convenience init(store: RecordingLibraryStoring) {
        self.init(
            store: store,
            transcriptionService: TranscriptionServiceFactory.makeDefault(),
            summaryService: UnavailableSummaryService(
                reason: .foundationModelsUnavailable("Foundation Models is unavailable on this Mac.")
            ),
            summaryStore: MeetingSummarySidecarStore(),
            mixdownService: RecordingMixdownService()
        )
    }

    init(
        store: RecordingLibraryStoring,
        transcriptionService: AudioTranscriptionService,
        summaryService: TranscriptSummaryService,
        summaryStore: MeetingSummaryStoring,
        mixdownService: RecordingLibraryMixdownServicing = RecordingMixdownService()
    ) {
        self.store = store
        self.trackAwareTranscriptionService = TrackAwareTranscriptionService(service: transcriptionService)
        self.summaryService = summaryService
        self.summaryStore = summaryStore
        self.mixdownService = mixdownService
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
        case .loadingSaved, .transcribing, .summarizing, .summaryProgress:
            return true
        case .idle, .summarized, .unavailable, .failed:
            return false
        }
    }

    var isRemixingSelectedItem: Bool {
        guard let selectedItem else {
            return false
        }

        if case .mixing(selectedItem.id) = remixState {
            return true
        }

        return false
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
        guard let selectedItem, selectedItem.hasTranscribableAudio else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        transcript = nil
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
        guard let selectedItem, selectedItem.hasTranscribableAudio else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        summaryState = .transcribing

        Task {
            do {
                let transcript = try await trackAwareTranscriptionService.finalTranscript(
                    systemAudioURL: item.existingSystemAudioURL,
                    microphoneURL: item.existingMicrophoneURL,
                    fallbackURL: item.hasUsableMixdown ? item.mixdownURL : nil,
                    locale: Locale(identifier: AppSettings.shared.preferences.localeIdentifier)
                )
                self.transcript = transcript
                try await summaryStore.save(transcript, for: item)
                summaryState = .summarizing
                let result = await summaryService.summarize(transcript) { [weak self] progress in
                    await self?.updateSummaryProgress(progress, for: item)
                }
                await handleSummaryResult(result, for: item)
            } catch {
                summaryState = .failed(error.localizedDescription)
            }
        }
    }

    func togglePlayback() {
        guard let selectedItem, selectedItem.hasUsableMixdown else {
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

    func remixSelectedItem() {
        guard let selectedItem, selectedItem.canRemix, !isRemixingSelectedItem else {
            return
        }

        let item = selectedItem
        remixState = .mixing(item.id)

        Task {
            do {
                _ = try await mixdownService.export(
                    systemAudioURL: item.existingSystemAudioURL,
                    microphoneURL: item.existingMicrophoneURL,
                    destinationURL: item.mixdownURL
                )
                remixState = .idle
                await refresh(shouldShowLoading: false)
            } catch {
                remixState = .failed(item.id, error.localizedDescription)
            }
        }
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

    private func updateSummaryProgress(_ progress: SummaryProgress, for item: RecordingLibraryItem) {
        guard selectedItem?.id == item.id else {
            return
        }
        summaryState = .summaryProgress(progress)
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
