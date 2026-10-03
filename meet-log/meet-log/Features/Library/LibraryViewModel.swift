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
        case cancelled
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
    @Published private(set) var savedSummary: MeetingSummary?
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
    private var processingTask: Task<Void, Never>?
    private var processingRunID: UUID?

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
        case .idle, .summarized, .unavailable, .failed, .cancelled:
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
        cancelProcessing()
        let request = UUID()
        summaryLoadID = request
        savedSummary = nil
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
                let savedTranscript = try await summaryStore.transcript(for: item)
                guard self.summaryLoadID == request, self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                transcript = savedTranscript
                let summary = try await summaryStore.summary(for: item)
                guard self.summaryLoadID == request, self.selectedItem?.mixdownURL == item.mixdownURL else {
                    return
                }
                savedSummary = summary
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

    var summaryInputWarning: String? {
        guard let savedSummary else {
            return nil
        }
        guard let fingerprint = savedSummary.inputFingerprint else {
            return "この要約の入力は記録されていません。保存済みテキストから再生成してください。"
        }
        guard fingerprint != transcript?.summaryInputFingerprint else {
            return nil
        }
        return "この要約は更新前の入力に基づいています。保存済みテキストから再生成してください。"
    }

    func unavailableReason(for stage: LibraryProcessingStage) -> String? {
        guard let item = selectedItem else {
            return "録音を選択してください。"
        }
        switch stage {
        case .all, .transcription:
            return item.hasTranscribableAudio ? nil : "文字起こしに必要な音声ファイルがありません。"
        case .screenOCR:
            return item.existingScreenCaptureURL == nil ? "画面OCRに必要な動画ファイルがありません。" : nil
        case .summary:
            guard let transcript, !transcript.summaryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "要約に必要な保存済みテキストがありません。"
            }
            return nil
        }
    }

    func generateSummaryForSelectedItem(template: SummaryTemplate? = nil) {
        runProcessing(.all, template: template)
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        guard processingRunID != nil else {
            return
        }
        processingRunID = nil
        summaryState = .cancelled
    }

    func runProcessing(_ stage: LibraryProcessingStage, template: SummaryTemplate? = nil) {
        guard !isSummaryBusy, let item = selectedItem else {
            return
        }
        // Saved text is reloaded below so external/manual edits are respected.
        if stage != .summary, let reason = unavailableReason(for: stage) {
            summaryState = .failed(reason)
            return
        }
        summaryLoadID = UUID()
        let runID = UUID()
        processingRunID = runID
        summaryState = stage.initialState
        screenOCRWarning = nil
        let locale = Locale(identifier: AppSettings.shared.preferences.localeIdentifier)
        let selectedTemplate = template ?? SummaryTemplate.builtIn

        processingTask = Task {
            defer {
                if processingRunID == runID {
                    processingRunID = nil
                    processingTask = nil
                }
            }
            do {
                let saved = try await summaryStore.transcript(for: item)
                try validateRun(runID, item: item)
                var input = saved ?? TranscriptResult(
                    text: "", localeIdentifier: locale.identifier, sourceURL: item.mixdownURL
                )
                if stage == .all || stage == .transcription {
                    input = try await trackAwareTranscriptionService.finalTranscript(
                        systemAudioURL: item.existingSystemAudioURL,
                        microphoneURL: item.existingMicrophoneURL,
                        fallbackURL: item.hasUsableMixdown ? item.mixdownURL : nil,
                        locale: locale
                    ).retainingScreen(from: saved)
                    try validateRun(runID, item: item)
                }
                if stage == .screenOCR || stage == .all {
                    input = try await recognizeScreen(input, item: item, stage: stage, runID: runID)
                    try validateRun(runID, item: item)
                }
                if stage != .summary {
                    try await summaryStore.save(input, for: item)
                    try validateRun(runID, item: item)
                }
                if stage == .summary, input.summaryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    summaryState = .failed("要約に必要な保存済みテキストがありません。")
                    return
                }
                transcript = input
                guard stage == .all || stage == .summary else {
                    summaryState = savedSummary.map(SummaryState.summarized) ?? .idle
                    scheduleSearch()
                    return
                }
                guard !input.summaryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    summaryState = .failed("要約に必要な保存済みテキストがありません。")
                    return
                }
                summaryState = .summarizing
                let result = await summaryService.summarize(input, template: selectedTemplate) { [weak self] progress in
                    await self?.updateSummaryProgress(progress, for: item, runID: runID)
                }
                try validateRun(runID, item: item)
                try await handleSummaryResult(result, input: input, for: item, runID: runID)
                scheduleSearch()
            } catch is CancellationError {
                if processingRunID == runID {
                    summaryState = .cancelled
                }
            } catch {
                guard processingRunID == runID else {
                    return
                }
                summaryState = .failed(error.localizedDescription)
            }
        }
    }

    private func validateRun(_ runID: UUID, item: RecordingLibraryItem) throws {
        try Task.checkCancellation()
        guard processingRunID == runID, selectedItem?.mixdownURL == item.mixdownURL else {
            throw CancellationError()
        }
    }

    private func recognizeScreen(
        _ input: TranscriptResult, item: RecordingLibraryItem,
        stage: LibraryProcessingStage, runID: UUID
    ) async throws -> TranscriptResult {
        guard let videoURL = item.existingScreenCaptureURL else {
            return input
        }
        summaryState = .recognizingScreen
        do {
            return try await screenEnricher.enrich(input, videoURL: videoURL)
        } catch {
            try validateRun(runID, item: item)
            guard stage == .all else {
                throw error
            }
            screenOCRWarning = "画面テキストを抽出できませんでした。前回の画面テキストを保持します: \(error.localizedDescription)"
            return input
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

        let notes: [RecordingNote]
        if let url = RecordingNoteStore().url(for: selectedItem.mixdownURL) {
            notes = (try? RecordingNoteStore().load(from: url)) ?? []
        } else {
            notes = []
        }

        return MeetingExportDocument(
            title: selectedItem.title,
            createdAt: selectedItem.createdAt,
            summary: savedSummary,
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

    private func updateSummaryProgress(_ progress: SummaryProgress, for item: RecordingLibraryItem, runID: UUID) {
        guard processingRunID == runID, selectedItem?.mixdownURL == item.mixdownURL else {
            return
        }
        summaryState = .summaryProgress(progress)
    }

    private func handleSummaryResult(
        _ result: TranscriptSummaryResult, input: TranscriptResult,
        for item: RecordingLibraryItem, runID: UUID
    ) async throws {
        switch result {
        case let .summarized(summary):
            let recorded = summary.recording(input: input)
            try await summaryStore.save(recorded, for: item)
            try validateRun(runID, item: item)
            savedSummary = recorded
            summaryState = .summarized(recorded)
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
