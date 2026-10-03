import AppKit
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
        case recognizingScreen
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

            stopPlayback()
            loadSummaryForSelectedItem()
        }
    }
    private var playbackStorage: MeetingPlaybackController?
    var playback: MeetingPlaybackController {
        if let playbackStorage {
            return playbackStorage
        }
        let controller = MeetingPlaybackController()
        playbackStorage = controller
        return controller
    }
    @Published private(set) var summaryState: SummaryState = .idle
    @Published private(set) var screenOCRWarning: String?
    @Published private(set) var transcript: TranscriptResult?
    @Published private(set) var remixState: RemixState = .idle
    @Published var selectedSummaryTemplateID = SummaryTemplate.builtIn.id
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else {
                return
            }
            scheduleSearch()
        }
    }
    @Published private(set) var searchProgress: LibrarySearchProgress?

    private let store: RecordingLibraryStoring
    private let trackAwareTranscriptionService: TrackAwareTranscriptionService
    private let screenEnricher: ScreenTranscriptEnricher
    private let summaryService: TranscriptSummaryService
    private let summaryStore: MeetingSummaryStoring
    private let mixdownService: RecordingLibraryMixdownServicing
    private let searchService: LibrarySearchService
    private var searchTask: Task<Void, Never>?
    private var summaryLoadID = UUID()

    convenience init() {
        self.init(
            store: SettingsRecordingLibraryStore(),
            transcriptionService: TranscriptionServiceFactory.makeDefault(),
            summaryService: SummaryServiceFactory.makeDefault(),
            summaryStore: MeetingSummarySidecarStore(),
            mixdownService: RecordingMixdownService()
        )
        selectedSummaryTemplateID = AppSettings.shared.preferences.summaryTemplateID
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
        mixdownService: RecordingLibraryMixdownServicing = RecordingMixdownService(),
        searchService: LibrarySearchService? = nil,
        screenOCRService: ScreenOCRServicing = ScreenOCRService()
    ) {
        self.store = store
        self.trackAwareTranscriptionService = TrackAwareTranscriptionService(service: transcriptionService)
        self.screenEnricher = ScreenTranscriptEnricher(service: screenOCRService)
        self.summaryService = summaryService
        self.summaryStore = summaryStore
        self.mixdownService = mixdownService
        self.searchService = searchService ?? LibrarySearchService(summaryStore: summaryStore)
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

    var searchResults: [LibrarySearchResult] {
        searchProgress?.results ?? []
    }

    var isSearching: Bool {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let searchProgress else {
            return false
        }
        return !searchProgress.isComplete
    }

    var isSummaryBusy: Bool {
        switch summaryState {
        case .loadingSaved, .transcribing, .recognizingScreen, .summarizing, .summaryProgress:
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
        let request = UUID()
        summaryLoadID = request
        transcript = nil
        screenOCRWarning = nil
        guard let selectedItem else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        summaryState = .loadingSaved

        Task {
            do {
                let savedTranscript = try? await summaryStore.transcript(for: item)
                guard self.summaryLoadID == request, self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                transcript = savedTranscript
                let summary = try await summaryStore.summary(for: item)
                guard self.summaryLoadID == request, self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                if let summary {
                    summaryState = .summarized(summary)
                } else {
                    summaryState = .idle
                }
            } catch {
                guard self.summaryLoadID == request, self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                summaryState = .failed(error.localizedDescription)
            }
        }
    }

    func generateSummaryForSelectedItem(template: SummaryTemplate? = nil) {
        summaryLoadID = UUID()
        guard let selectedItem, selectedItem.hasTranscribableAudio else {
            summaryState = .idle
            return
        }

        let item = selectedItem
        summaryState = .transcribing
        screenOCRWarning = nil

        Task {
            do {
                var transcript = try await trackAwareTranscriptionService.finalTranscript(
                    systemAudioURL: item.existingSystemAudioURL,
                    microphoneURL: item.existingMicrophoneURL,
                    fallbackURL: item.hasUsableMixdown ? item.mixdownURL : nil,
                    locale: Locale(identifier: AppSettings.shared.preferences.localeIdentifier)
                )
                if let videoURL = item.existingScreenCaptureURL {
                    if self.selectedItem?.mixdownURL == item.mixdownURL {
                        summaryState = .recognizingScreen
                    }
                    do {
                        transcript = try await screenEnricher.enrich(transcript, videoURL: videoURL)
                    } catch {
                        if self.selectedItem?.mixdownURL == item.mixdownURL {
                            screenOCRWarning = "画面テキストを抽出できませんでした。音声の処理を続けます: \(error.localizedDescription)"
                        }
                    }
                }
                try await summaryStore.save(transcript, for: item)
                if self.selectedItem?.mixdownURL == item.mixdownURL {
                    self.transcript = transcript
                    summaryState = .summarizing
                }
                let selectedTemplate = template ?? SummaryTemplate.builtIn
                let result = await summaryService.summarize(
                    transcript,
                    template: selectedTemplate
                ) { [weak self] progress in
                    await self?.updateSummaryProgress(progress, for: item)
                }
                await handleSummaryResult(result, for: item)
            } catch {
                guard self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                summaryState = .failed(error.localizedDescription)
            }
        }
    }

    func stopPlayback() {
        playbackStorage?.stop()
    }

    func revealSelectedItemInFinder() {
        guard let selectedItem else {
            return
        }

        LibraryFinder.reveal(fileURL: selectedItem.mixdownURL)
    }

    func exportDocumentForSelectedItem() -> MeetingExportDocument? {
        guard let selectedItem else {
            return nil
        }

        let summary: MeetingSummary?
        if case let .summarized(savedSummary) = summaryState {
            summary = savedSummary
        } else {
            summary = nil
        }

        let notes: [RecordingNote]
        if let url = RecordingNoteStore().url(for: selectedItem.mixdownURL) {
            notes = (try? RecordingNoteStore().load(from: url)) ?? []
        } else {
            notes = []
        }

        return MeetingExportDocument(
            title: selectedItem.title,
            createdAt: selectedItem.createdAt,
            summary: summary,
            transcript: transcript,
            notes: notes
        )
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
            scheduleSearch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchProgress = nil
            return
        }

        let searchableItems = items
        searchProgress = LibrarySearchProgress(
            results: [],
            scannedCount: 0,
            totalCount: searchableItems.count,
            unprocessedCount: 0,
            isComplete: searchableItems.isEmpty
        )
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }
            for await progress in searchService.search(query: query, items: searchableItems) {
                guard !Task.isCancelled else {
                    return
                }
                searchProgress = progress
            }
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
                guard self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                summaryState = .summarized(summary)
            } catch {
                guard self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                summaryState = .failed(error.localizedDescription)
            }
        case let .unavailable(reason):
            guard self.selectedItem?.mixdownURL == item.mixdownURL else {
                return
            }
            summaryState = .unavailable(reason.localizedDescription)
        case let .failed(error):
            guard self.selectedItem?.mixdownURL == item.mixdownURL else {
                return
            }
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
