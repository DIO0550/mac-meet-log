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

    struct ProcessingConfirmation: Identifiable {
        let id = UUID()
        let stage: LibraryProcessingStage
        let template: SummaryTemplate?
        let message: String
    }

    // IDs can repeat in a different destination. Include the captured storage URL.
    private struct RecordingKey: Hashable, Sendable {
        let id: RecordingLibraryItem.ID
        let mixdownURL: URL

        init(_ item: RecordingLibraryItem) {
            id = item.id
            mixdownURL = item.mixdownURL
        }
    }

    private struct Run: Equatable, Sendable {
        let recording: RecordingKey
        let id = UUID()
    }

    private struct RecordingResult {
        let run: Run
        var state: SummaryState = .idle
        var summary: MeetingSummary?
        var transcript: TranscriptResult?
        var screenOCRWarning: String?
        var confirmation: ProcessingConfirmation?
    }

    @Published private var recordingResults: [RecordingKey: RecordingResult] = [:]

    private var selectedResult: RecordingResult? {
        guard let selectedItem else {
            return nil
        }
        return recordingResults[RecordingKey(selectedItem)]
    }

    private func updateSelectedResult(_ update: (inout RecordingResult) -> Void) {
        guard let run = selectedResult?.run else {
            return
        }
        updateResult(for: run, update)
    }

    private func updateResult(for run: Run, _ update: (inout RecordingResult) -> Void) {
        guard var result = recordingResults[run.recording], result.run == run else {
            return
        }
        update(&result)
        recordingResults[run.recording] = result
    }

    @Published private(set) var metadataItem: RecordingLibraryItem?
    @Published private(set) var trashPlan: LibraryTrashPlan?
    @Published var managementMessage: String?
    @Published var selectedTag: String? { didSet { scheduleSearch() } }
    private let trashService: LibraryTrashService
    private var editingActivity: UUID?
    var availableTags: [String] { Array(Set(items.flatMap(\.tags))).sorted() }
    var filteredItems: [RecordingLibraryItem] {
        guard let selectedTag else { return items }
        return items.filter { $0.tags.contains(selectedTag) }
    }

    func beginMetadataEditing() {
        guard let item = selectedItem else { return }
        guard !LibraryActivity.isBusy(item.mixdownURL), !isSummaryBusy else {
            managementMessage = LibraryManagementError.busy.localizedDescription
            return
        }
        managementMessage = nil
        metadataItem = item
    }

    func cancelMetadataEditing() {
        guard metadataItem != nil else { return }
        managementMessage = nil
        metadataItem = nil
    }

    func cancelTrash() {
        // SwiftUI may notify dismissal after a successful move; retain its result message.
        guard trashPlan != nil else { return }
        managementMessage = nil
        trashPlan = nil
    }

    func saveMetadata(name: String, tags: [String]) async {
        guard let item = metadataItem else { return }
        do {
            var metadata = try RecordingDisplayMetadataStore().load(stem: item.storageStem, directory: item.sessionDirectoryURL)
                ?? RecordingDisplayMetadata(name: item.title, tags: item.tags, createdAt: item.createdAt)
            metadata.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.tags = RecordingDisplayMetadata(name: name, tags: tags, createdAt: item.createdAt).tags
            try trashService.saveMetadata(metadata, for: item)
            cancelMetadataEditing()
            await refresh(shouldShowLoading: false)
        } catch { managementMessage = error.localizedDescription }
    }

    func prepareTrash(_ scope: LibraryTrashScope) {
        guard let item = selectedItem else { return }
        do {
            guard !LibraryActivity.isBusy(item.mixdownURL), !isSummaryBusy else { throw LibraryManagementError.busy }
            let plan = try trashService.plan(for: item, scope: scope)
            guard !plan.files.isEmpty else {
                managementMessage = "移動できる対象ファイルがありません。再読み込みしてください。"
                return
            }
            managementMessage = nil
            trashPlan = plan
        } catch { managementMessage = error.localizedDescription }
    }

    func confirmTrash() async {
        guard let plan = trashPlan else { return }
        do {
            guard !LibraryActivity.isBusy(plan.item.mixdownURL) else { throw LibraryManagementError.busy }
            stopPlayback()
            let result = try trashService.execute(plan)
            trashPlan = nil
            managementMessage = result.message
            await refresh(shouldShowLoading: false)
        } catch { managementMessage = error.localizedDescription }
    }

    @Published var editDraft: MeetingEditDraft?
    @Published private(set) var isSavingEdits = false
    @Published private(set) var editError: String?
    private(set) var processingConfirmation: ProcessingConfirmation? {
        get { selectedResult?.confirmation }
        set { updateSelectedResult { $0.confirmation = newValue } }
    }
    private var editingItem: RecordingLibraryItem?

    @Published private(set) var state: State = .loading
    @Published private var selectedRecordingID: RecordingLibraryItem.ID?
    var selectedID: RecordingLibraryItem.ID? {
        get { selectedRecordingID }
        set {
            guard editDraft == nil, metadataItem == nil, trashPlan == nil, selectedRecordingID != newValue else {
                return
            }
            selectedRecordingID = newValue
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
    private(set) var summaryState: SummaryState {
        get {
            if refreshRunID != nil {
                return .loadingSaved
            }
            return selectedResult?.state ?? .idle
        }
        set { updateSelectedResult { $0.state = newValue } }
    }
    private(set) var savedSummary: MeetingSummary? {
        get { selectedResult?.summary }
        set { updateSelectedResult { $0.summary = newValue } }
    }
    private(set) var screenOCRWarning: String? {
        get { selectedResult?.screenOCRWarning }
        set { updateSelectedResult { $0.screenOCRWarning = newValue } }
    }
    private(set) var transcript: TranscriptResult? {
        get { selectedResult?.transcript }
        set { updateSelectedResult { $0.transcript = newValue } }
    }
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

    private static let missingSummaryInputMessage = "要約に必要な保存済みテキストがありません。"

    private let store: RecordingLibraryStoring
    private let trackAwareTranscriptionService: TrackAwareTranscriptionService
    private let screenEnricher: ScreenTranscriptEnricher
    private let summaryService: TranscriptSummaryService
    private let summaryStore: MeetingSummaryStoring
    private let mixdownService: RecordingLibraryMixdownServicing
    private let searchService: LibrarySearchService
    private var searchTask: Task<Void, Never>?
    private var summaryLoadTask: Task<Void, Never>?
    private var summaryLoadRun: Run?
    private var processingTasks: [RecordingKey: (run: Run, task: Task<Void, Never>)] = [:]
    private var refreshTask: Task<Void, Never>?
    @Published private var refreshRunID: UUID?

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
        screenOCRService: ScreenOCRServicing = ScreenOCRService(),
        trashService: LibraryTrashService = LibraryTrashService()
    ) {
        self.store = store
        self.trashService = trashService
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
        await summaryLoadTask?.value
    }

    func refresh() {
        guard let request = beginRefresh(shouldShowLoading: false) else {
            return
        }
        refreshTask = Task {
            await performRefresh(request: request)
        }
    }

    func select(_ item: RecordingLibraryItem) {
        selectedID = item.id
    }

    func loadSummaryForSelectedItem() {
        guard editDraft == nil, refreshRunID == nil else {
            return
        }
        cancelSummaryLoad()
        guard let item = selectedItem else {
            return
        }
        let key = RecordingKey(item)
        // Selection only changes the visible result; generation still belongs to its recording.
        guard processingTasks[key] == nil else {
            return
        }
        let run = Run(recording: key)
        recordingResults[key] = RecordingResult(run: run, state: .loadingSaved)
        summaryLoadRun = run

        summaryLoadTask = Task {
            defer {
                if summaryLoadRun == run {
                    summaryLoadRun = nil
                    summaryLoadTask = nil
                }
            }
            do {
                let savedTranscript = try await summaryStore.transcript(for: item)
                try validateRun(run)
                updateResult(for: run) { $0.transcript = savedTranscript }
                let summary = try await summaryStore.summary(for: item)
                try validateRun(run)
                updateResult(for: run) {
                    $0.summary = summary
                    $0.state = summary.map(SummaryState.summarized) ?? .idle
                }
            } catch is CancellationError {
                // A replacement load or refresh owns the visible state now.
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                updateResult(for: run) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func cancelSummaryLoad() {
        summaryLoadTask?.cancel()
        summaryLoadTask = nil
        if let run = summaryLoadRun, recordingResults[run.recording]?.run == run {
            recordingResults[run.recording] = nil
        }
        summaryLoadRun = nil
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
                return Self.missingSummaryInputMessage
            }
            return nil
        }
    }

    func generateSummaryForSelectedItem(template: SummaryTemplate? = nil) {
        runProcessing(.all, template: template)
    }

    func cancelProcessing() {
        guard let item = selectedItem,
              let processing = processingTasks[RecordingKey(item)] else {
            return
        }
        processing.task.cancel()
        processingTasks[processing.run.recording] = nil
        // A fresh execution identity rejects even callbacks that ignore cancellation.
        if var result = recordingResults[processing.run.recording] {
            result = RecordingResult(
                run: Run(recording: processing.run.recording), state: .cancelled,
                summary: result.summary, transcript: result.transcript,
                screenOCRWarning: result.screenOCRWarning
            )
            recordingResults[processing.run.recording] = result
        }
    }

    func beginTranscriptEditing() {
        guard metadataItem == nil, trashPlan == nil, !isSummaryBusy, editDraft == nil, let transcript, let item = selectedItem else { return }
        guard !LibraryActivity.isBusy(item.mixdownURL) else {
            return
        }
        editingItem = item
        editingActivity = LibraryActivity.begin(item.mixdownURL)
        editError = nil
        editDraft = MeetingEditDraft(transcript: transcript)
    }

    func beginSummaryEditing() {
        guard metadataItem == nil, trashPlan == nil, !isSummaryBusy, editDraft == nil, let savedSummary, let item = selectedItem else { return }
        guard !LibraryActivity.isBusy(item.mixdownURL) else {
            return
        }
        editingItem = item
        editingActivity = LibraryActivity.begin(item.mixdownURL)
        editError = nil
        editDraft = MeetingEditDraft(summary: savedSummary)
    }

    func discardEdits() {
        guard !isSavingEdits else { return }
        editDraft = nil
        editingItem = nil
        LibraryActivity.end(editingActivity)
        editingActivity = nil
        editError = nil
    }

    func saveEdits() async {
        guard !isSavingEdits, let draft = editDraft, let item = editingItem,
              selectedItem?.mixdownURL == item.mixdownURL else { return }
        guard draft.hasChanges else {
            discardEdits()
            return
        }
        isSavingEdits = true
        editError = nil
        defer { isSavingEdits = false }
        do {
            switch draft.original {
            case .transcript(let original):
                guard try await summaryStore.transcript(for: item) == original else {
                    throw SummaryError.persistenceFailed("保存済みの文字起こしが変更されています。編集を取り消して読み直してください。")
                }
                guard let edited = draft.editedTranscript() else {
                    throw SummaryError.persistenceFailed("セグメントの構成が変更されています。")
                }
                try await summaryStore.save(edited, for: item)
                transcript = edited
            case .summary(let original):
                // Legacy Markdown has no topic/TODO IDs; decoding assigns fresh UUIDs.
                guard let stored = try await summaryStore.summary(for: item),
                      stored == original || (stored.editedAt == nil && original.editedAt == nil &&
                        MeetingSummaryMarkdownCodec.encode(stored, recordingID: item.id)
                        == MeetingSummaryMarkdownCodec.encode(original, recordingID: item.id)) else {
                    throw SummaryError.persistenceFailed("保存済みの要約が変更されています。編集を取り消して読み直してください。")
                }
                guard let edited = draft.editedSummary() else { return }
                try await summaryStore.save(edited, for: item)
                savedSummary = edited
                summaryState = .summarized(edited)
            }
            editDraft = nil
            editingItem = nil
            LibraryActivity.end(editingActivity)
            editingActivity = nil
            scheduleSearch()
        } catch {
            editError = error.localizedDescription
        }
    }

    func cancelProcessingConfirmation() {
        processingConfirmation = nil
    }

    func confirmProcessingOverwrite() {
        guard let confirmation = processingConfirmation else { return }
        processingConfirmation = nil
        runProcessing(confirmation.stage, template: confirmation.template, overwriteConfirmed: true)
    }

    private func overwriteWarning(
        for stage: LibraryProcessingStage, transcript: TranscriptResult?, summary: MeetingSummary?
    ) -> String? {
        var names: [String] = []
        if (stage == .all || stage == .transcription), transcript?.audioEditedAt != nil {
            names.append("音声の文字起こし")
        }
        if (stage == .all || stage == .screenOCR), transcript?.screenEditedAt != nil {
            names.append("画面OCR")
        }
        if (stage == .all || stage == .summary), summary?.editedAt != nil {
            names.append("要約・トピック・TODO")
        }
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: "、"))の手動修正が再生成結果で上書きされます。続けますか？"
    }

    func runProcessing(_ stage: LibraryProcessingStage, template: SummaryTemplate? = nil, overwriteConfirmed: Bool = false) {
        guard metadataItem == nil, trashPlan == nil, !isSummaryBusy, editDraft == nil, let item = selectedItem else {
            return
        }
        guard !LibraryActivity.isBusy(item.mixdownURL) else {
            return
        }
        // Saved text is reloaded below so external/manual edits are respected.
        if stage != .summary, let reason = unavailableReason(for: stage) {
            summaryState = .failed(reason)
            return
        }
        cancelSummaryLoad()
        let key = RecordingKey(item)
        let run = Run(recording: key)
        let previous = recordingResults[key]
        recordingResults[key] = RecordingResult(
            run: run, state: stage.initialState,
            summary: previous?.summary, transcript: previous?.transcript
        )
        let locale = Locale(identifier: AppSettings.shared.preferences.localeIdentifier)
        let selectedTemplate = template ?? SummaryTemplate.builtIn

        let activity = LibraryActivity.begin(item.mixdownURL)
        let task = Task {
            defer {
                LibraryActivity.end(activity)
                if processingTasks[key]?.run == run {
                    processingTasks[key] = nil
                }
            }
            do {
                let saved = try await summaryStore.transcript(for: item)
                try validateRun(run)
                if !overwriteConfirmed,
                   let warning = overwriteWarning(for: stage, transcript: saved, summary: previous?.summary) {
                    updateResult(for: run) {
                        $0.confirmation = ProcessingConfirmation(stage: stage, template: template, message: warning)
                        $0.state = $0.summary.map(SummaryState.summarized) ?? .idle
                    }
                    return
                }
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
                    try validateRun(run)
                }
                if stage == .screenOCR || stage == .all {
                    input = try await recognizeScreen(input, item: item, stage: stage, run: run)
                    try validateRun(run)
                }
                if stage != .summary {
                    try await summaryStore.save(input, for: item)
                    try validateRun(run)
                }
                if stage == .summary, input.summaryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updateResult(for: run) { $0.state = .failed(Self.missingSummaryInputMessage) }
                    return
                }
                updateResult(for: run) { $0.transcript = input }
                guard stage == .all || stage == .summary else {
                    updateResult(for: run) { $0.state = $0.summary.map(SummaryState.summarized) ?? .idle }
                    scheduleSearch()
                    return
                }
                guard !input.summaryInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    updateResult(for: run) { $0.state = .failed(Self.missingSummaryInputMessage) }
                    return
                }
                updateResult(for: run) { $0.state = .summarizing }
                let result = await summaryService.summarize(input, template: selectedTemplate) { [weak self] progress in
                    await self?.updateSummaryProgress(progress, run: run)
                }
                try validateRun(run)
                try await handleSummaryResult(result, input: input, for: item, run: run)
                scheduleSearch()
            } catch is CancellationError {
                updateResult(for: run) { $0.state = .cancelled }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                updateResult(for: run) { $0.state = .failed(error.localizedDescription) }
            }
        }
        processingTasks[key] = (run, task)
    }

    private func validateRun(_ run: Run) throws {
        try Task.checkCancellation()
        guard recordingResults[run.recording]?.run == run else {
            throw CancellationError()
        }
    }

    private func recognizeScreen(
        _ input: TranscriptResult, item: RecordingLibraryItem,
        stage: LibraryProcessingStage, run: Run
    ) async throws -> TranscriptResult {
        guard let videoURL = item.existingScreenCaptureURL else {
            return input
        }
        updateResult(for: run) { $0.state = .recognizingScreen }
        do {
            return try await screenEnricher.enrich(input, videoURL: videoURL)
        } catch {
            try validateRun(run)
            guard stage == .all else {
                throw error
            }
            updateResult(for: run) {
                $0.screenOCRWarning = "画面テキストを抽出できませんでした。前回の画面テキストを保持します: \(error.localizedDescription)"
            }
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
        let result = recordingResults[RecordingKey(selectedItem)]

        let notes: [RecordingNote]
        if let url = RecordingNoteStore().url(for: selectedItem.mixdownURL) {
            notes = (try? RecordingNoteStore().load(from: url)) ?? []
        } else {
            notes = []
        }

        return MeetingExportDocument(
            title: selectedItem.title,
            createdAt: selectedItem.createdAt,
            summary: result?.summary,
            transcript: result?.transcript,
            notes: notes
        )
    }

    func remixSelectedItem() {
        guard metadataItem == nil, trashPlan == nil, let selectedItem, selectedItem.canRemix, !isRemixingSelectedItem else {
            return
        }

        let item = selectedItem
        remixState = .mixing(item.id)
        let activity = LibraryActivity.begin(item.mixdownURL)

        Task {
            defer { LibraryActivity.end(activity) }
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
        guard let request = beginRefresh(shouldShowLoading: shouldShowLoading) else {
            return
        }
        await performRefresh(request: request)
    }

    private func beginRefresh(shouldShowLoading: Bool) -> UUID? {
        guard editDraft == nil, metadataItem == nil, trashPlan == nil else {
            return nil
        }
        refreshTask?.cancel()
        refreshTask = nil
        cancelSummaryLoad()
        for processing in processingTasks.values {
            processing.task.cancel()
        }
        processingTasks.removeAll()
        recordingResults.removeAll()
        searchTask?.cancel()
        searchProgress = nil
        stopPlayback()

        let request = UUID()
        refreshRunID = request
        if shouldShowLoading {
            state = .loading
        }
        return request
    }

    private func performRefresh(request: UUID) async {
        defer {
            if refreshRunID == request {
                refreshRunID = nil
                refreshTask = nil
            }
        }
        do {
            let loadedItems = try await store.recordings()
            guard refreshRunID == request, !Task.isCancelled,
                  editDraft == nil, metadataItem == nil, trashPlan == nil else {
                return
            }
            reconcileSelection(with: loadedItems)
            state = loadedItems.isEmpty ? .empty : .loaded(loadedItems)
            refreshRunID = nil
            refreshTask = nil
            loadSummaryForSelectedItem()
            scheduleSearch()
        } catch {
            guard refreshRunID == request, !Task.isCancelled else {
                return
            }
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

        let searchableItems = filteredItems
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

    private func updateSummaryProgress(_ progress: SummaryProgress, run: Run) {
        guard processingTasks[run.recording]?.run == run else {
            return
        }
        updateResult(for: run) { $0.state = .summaryProgress(progress) }
    }

    private func handleSummaryResult(
        _ result: TranscriptSummaryResult, input: TranscriptResult,
        for item: RecordingLibraryItem, run: Run
    ) async throws {
        switch result {
        case let .summarized(summary):
            let recorded = summary.recording(input: input)
            try await summaryStore.save(recorded, for: item)
            try validateRun(run)
            updateResult(for: run) {
                $0.summary = recorded
                $0.state = .summarized(recorded)
            }
        case let .unavailable(reason):
            updateResult(for: run) { $0.state = .unavailable(reason.localizedDescription) }
        case let .failed(error):
            updateResult(for: run) { $0.state = .failed(error.localizedDescription) }
        }
    }

    private func reconcileSelection(with loadedItems: [RecordingLibraryItem]) {
        guard !loadedItems.isEmpty else {
            selectedRecordingID = nil
            return
        }

        if let selectedID, loadedItems.contains(where: { $0.id == selectedID }) {
            return
        }

        selectedRecordingID = loadedItems.first?.id
    }
}
