import SwiftUI
import DualTrackRecorder

struct LibraryView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var viewModel: LibraryViewModel
    let recorderAction: () -> Void

    @MainActor
    init(recorderAction: @escaping () -> Void) {
        self.init(
            viewModel: LibraryViewModel(),
            recorderAction: recorderAction
        )
    }

    @MainActor
    init(
        viewModel: @autoclosure @escaping () -> LibraryViewModel,
        recorderAction: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.recorderAction = recorderAction
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            content
                .disabled(viewModel.audioImportState == .importing)
        }
        .frame(minWidth: 920, idealWidth: 980, minHeight: 580, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
        .onChange(of: settings.directoryRevision) {
            viewModel.cancelAudioImport()
            viewModel.stopPlayback()
            viewModel.refresh()
        }
        .fileImporter(
            isPresented: $viewModel.isAudioImporterPresented,
            allowedContentTypes: AudioImportAllowedContentTypes.values,
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleAudioImporterResult(firstSelectedURL(from: result))
        }
        .onDisappear {
            viewModel.cancelAudioImport()
            viewModel.discardEdits()
            viewModel.stopPlayback()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editDraft != nil },
            set: { _ in } // Dismiss only through Save or the explicit discard confirmation.
        )) {
            if let initial = viewModel.editDraft {
                MeetingEditorView(
                    draft: Binding(get: { viewModel.editDraft ?? initial }, set: { viewModel.editDraft = $0 }),
                    isSaving: viewModel.isSavingEdits, error: viewModel.editError,
                    save: { Task { await viewModel.saveEdits() } }, cancel: viewModel.discardEdits
                )
            }
        }
        .sheet(item: Binding(
            get: { viewModel.metadataItem },
            set: { if $0 == nil { viewModel.cancelMetadataEditing() } }
        )) { item in
            LibraryMetadataEditor(item: item, save: { name, tags in
                Task { await viewModel.saveMetadata(name: name, tags: tags) }
            }, cancel: viewModel.cancelMetadataEditing, message: viewModel.managementMessage)
        }
        .sheet(item: Binding(
            get: { viewModel.trashPlan },
            set: { if $0 == nil { viewModel.cancelTrash() } }
        )) { plan in
            LibraryTrashConfirmation(plan: plan, confirm: {
                Task { await viewModel.confirmTrash() }
            }, cancel: viewModel.cancelTrash, message: viewModel.managementMessage)
        }
        .alert("Library", isPresented: Binding(
            get: { viewModel.managementMessage != nil && viewModel.metadataItem == nil && viewModel.trashPlan == nil },
            set: { if !$0 { viewModel.managementMessage = nil } }
        )) {
            Button("OK") { viewModel.managementMessage = nil }
        } message: { Text(viewModel.managementMessage ?? "") }
        .alert("手動修正を上書きしますか？", isPresented: Binding(
            get: { viewModel.processingConfirmation != nil },
            set: { if !$0 { viewModel.cancelProcessingConfirmation() } }
        )) {
            Button("再生成して上書き", role: .destructive, action: viewModel.confirmProcessingOverwrite)
            Button("キャンセル", role: .cancel, action: viewModel.cancelProcessingConfirmation)
        } message: {
            Text(viewModel.processingConfirmation?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: recorderAction) {
                    Label("Recorder", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Library")
                        .font(.title3.weight(.semibold))

                    Text("Saved mixdowns from \((try? settings.resolveOutputDirectory().path) ?? "Unavailable folder")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: viewModel.presentAudioImporter) {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canImportAudio)

                Button(action: viewModel.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.audioImportState == .importing)
            }

            audioImportStatus
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var audioImportStatus: some View {
        switch viewModel.audioImportState {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing audio...")
                    .font(.caption.weight(.medium))
                Button("Cancel", action: viewModel.cancelAudioImport)
            }
            .foregroundStyle(.secondary)
        case let .imported(item):
            Label(
                "\(item.title) was copied to Library. Processing results appear below.",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .lineLimit(1)
            .truncationMode(.middle)
        case let .failed(error):
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Label("Audio import cancelled.", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func firstSelectedURL(from result: Result<[URL], Error>) -> Result<URL, Error> {
        result.flatMap { urls in
            guard let url = urls.first else {
                return .failure(CocoaError(.userCancelled))
            }

            return .success(url)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LibraryStatusView(
                systemImage: "waveform",
                title: "Loading recordings",
                message: "Scanning the meet-log output folder."
            )
        case .empty:
            LibraryStatusView(
                systemImage: "tray",
                title: "No recordings yet",
                message: "Record a meeting and the saved mixdown will appear here.",
                actionTitle: "Back to Recorder",
                action: recorderAction
            )
        case let .failed(message):
            LibraryStatusView(
                systemImage: "exclamationmark.triangle",
                title: "Library could not load",
                message: message,
                actionTitle: "Try Again",
                action: viewModel.refresh
            )
        case .loaded:
            HSplitView {
                LibraryListPane(viewModel: viewModel)
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 420)

                LibraryDetailPane(viewModel: viewModel)
                    .frame(minWidth: 560)
            }
        }
    }
}

private struct LibraryListPane: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("会議名・タグ・要約・文字起こし・メモを検索", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Picker("タグ", selection: $viewModel.selectedTag) {
                Text("すべてのタグ").tag(String?.none)
                ForEach(viewModel.availableTags, id: \.self) { tag in
                    Text(tag).tag(Optional(tag))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            HStack {
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if isSearchActive {
                searchResults
            } else {
                List(selection: $viewModel.selectedID) {
                    ForEach(viewModel.filteredItems) { item in
                        LibraryItemRow(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.select(item)
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var isSearchActive: Bool {
        !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusText: String {
        guard isSearchActive, let progress = viewModel.searchProgress else {
            return "\(viewModel.items.count) recordings"
        }
        if progress.isComplete {
            return "\(progress.results.count) results"
        }
        return "Searching \(progress.scannedCount) / \(progress.totalCount)"
    }

    @ViewBuilder
    private var searchResults: some View {
        if let progress = viewModel.searchProgress,
           progress.isComplete,
           progress.results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("一致する録音はありません")
                    .font(.callout.weight(.medium))
                Text("別のキーワードで検索してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $viewModel.selectedID) {
                ForEach(viewModel.searchResults) { result in
                    LibrarySearchResultRow(result: result)
                        .tag(result.item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.select(result.item)
                        }
                }
            }
            .listStyle(.sidebar)
        }

        if let progress = viewModel.searchProgress, progress.unprocessedCount > 0 {
            Label(
                "文字起こし・要約がない録音 \(progress.unprocessedCount) 件は本文検索の対象外です。",
                systemImage: "info.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct LibrarySearchResultRow: View {
    let result: LibrarySearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.item.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(Array(result.matches.prefix(2)), id: \.section) { match in
                VStack(alignment: .leading, spacing: 3) {
                    Label(match.section.title, systemImage: match.section.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    highlightedText(match.snippet)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            if result.matches.count > 2 {
                Text("ほか \(result.matches.count - 2) 項目に一致")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

    private func highlightedText(_ snippet: LibrarySearchSnippet) -> Text {
        Text(snippet.prefix)
            + Text(snippet.match).bold().foregroundStyle(.tint)
            + Text(snippet.suffix)
    }
}

private struct LibraryItemRow: View {
    let item: RecordingLibraryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIconName)
                .foregroundStyle(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.tint)
                }
                Text(item.dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.durationText)
                    Text("·")
                    Text(item.sourceSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusIconName: String {
        if item.canRemix {
            return "waveform.badge.plus"
        }

        if item.hasMissingFiles {
            return "waveform.badge.exclamationmark"
        }

        return "waveform"
    }

    private var statusColor: Color {
        item.canRemix || item.hasMissingFiles ? .orange : .blue
    }
}

private struct LibraryDetailPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var viewModel: LibraryViewModel
    @State private var exportDocument: MeetingExportDocument?

    var body: some View {
        if let item = viewModel.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let report = try? RecordingRecoveryStore.loadReport(in: item.sessionDirectoryURL) {
                        GroupBox("復旧結果・欠損の可能性") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(report.messages.enumerated()), id: \.offset) { _, message in
                                    Text(message).font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    titleBlock(item)
                    LibraryManagementActions(viewModel: viewModel)
                    if item.screenRemoved {
                        Label("画面動画は削除済みです。動画再生・再OCRは利用できません。保存済みOCRは引き続き利用できます。", systemImage: "video.slash")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let warning = item.metadataWarning {
                        Text(warning).foregroundStyle(.orange)
                    }
                    actions
                    MeetingPlaybackView(controller: viewModel.playback, source: PlaybackSource(item: item))
                    transcriptSection
                    ScreenTranscriptView(
                        transcript: viewModel.transcript, warning: viewModel.screenOCRWarning,
                        seek: viewModel.playback.jump
                    )
                    summarySection(item)
                    if let url = RecordingNoteStore().url(for: item.mixdownURL) {
                        SavedRecordingNotesView(url: url, duration: item.duration, seek: viewModel.playback.jump)
                            .id(url)
                    }
                    fileStatus(item)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $exportDocument) { document in
                MeetingExportView(document: document)
            }
        } else {
            LibraryStatusView(
                systemImage: "sidebar.left",
                title: "Select a recording",
                message: "Choose a saved mixdown to inspect files and playback."
            )
        }
    }

    private func titleBlock(_ item: RecordingLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)

                if item.canRemix {
                    Label("Needs mix", systemImage: "waveform.badge.plus")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else if item.hasMissingFiles {
                    Label("Files missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Text(item.mixdownURL.lastPathComponent)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 14) {
                Label(item.dateText, systemImage: "calendar")
                Label(item.durationText, systemImage: "clock")
                Label(item.sourceSummary, systemImage: "speaker.wave.2")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let item = viewModel.selectedItem {
            actions(for: item)
        }
    }

    private func actions(for item: RecordingLibraryItem) -> some View {
        HStack(spacing: 10) {
            if item.canRemix {
                Button(action: viewModel.remixSelectedItem) {
                    Label(
                        viewModel.isRemixingSelectedItem ? "Mixing..." : "Create Mix",
                        systemImage: viewModel.isRemixingSelectedItem ? "hourglass" : "waveform.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRemixingSelectedItem)
            }

            Button(action: viewModel.revealSelectedItemInFinder) {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Picker("Template", selection: $viewModel.selectedSummaryTemplateID) {
                ForEach(settings.summaryTemplates) { template in
                    Text(template.name).tag(template.id)
                }
            }
            .frame(maxWidth: 190)

            Menu {
                ForEach(LibraryProcessingStage.allCases) { stage in
                    Button {
                        viewModel.runProcessing(
                            stage, template: settings.summaryTemplate(id: viewModel.selectedSummaryTemplateID)
                        )
                    } label: {
                        if let reason = viewModel.unavailableReason(for: stage) {
                            Text("\(stage.title) — \(reason)")
                        } else {
                            Text(stage.title)
                        }
                    }
                    .disabled(viewModel.unavailableReason(for: stage) != nil)
                }
            } label: {
                Label("処理を実行", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isSummaryBusy)

            if viewModel.isSummaryBusy, viewModel.summaryState != .loadingSaved {
                Button("キャンセル", action: viewModel.cancelProcessing)
            }

            Button {
                exportDocument = viewModel.exportDocumentForSelectedItem()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            if case let .failed(id, message) = viewModel.remixState, id == item.id {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let transcript = viewModel.transcript {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Transcript").font(.headline)
                    Text(transcript.audioEditedAt == nil ? "音声: 自動生成" : "音声: 手動修正済み")
                        .font(.caption).foregroundStyle(.secondary)
                    if !transcript.screenSegments.isEmpty {
                        Text(transcript.screenEditedAt == nil ? "画面: 自動生成" : "画面: 手動修正済み")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("編集", action: viewModel.beginTranscriptEditing)
                        .disabled(viewModel.isSummaryBusy)
                }

                if let report = transcript.transcriptionReport {
                    SummaryMessageRow(systemImage: "exclamationmark.triangle", message: report.warningText)
                }
                PlaybackTranscriptView(transcript: transcript, seek: viewModel.playback.jump)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func summarySection(_ item: RecordingLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Summary")
                    .font(.headline)

                Spacer(minLength: 0)

                if viewModel.isSummaryBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let summary = viewModel.savedSummary {
                HStack {
                    Text(summary.editedAt == nil ? "自動生成" : "手動修正済み")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("編集", action: viewModel.beginSummaryEditing)
                        .disabled(viewModel.isSummaryBusy)
                }
                if let warning = viewModel.summaryInputWarning {
                    SummaryMessageRow(systemImage: "exclamationmark.triangle", message: warning)
                }
                if let report = summary.transcriptionReport {
                    SummaryMessageRow(systemImage: "exclamationmark.triangle", message: report.warningText)
                }
                MeetingSummaryView(summary: summary, transcript: viewModel.transcript, seek: viewModel.playback.jump)
            }

            switch viewModel.summaryState {
            case .idle:
                if viewModel.savedSummary == nil {
                    let idleMessage = summaryIdleMessage(for: item)
                    SummaryMessageRow(systemImage: idleMessage.systemImage, message: idleMessage.message)
                }
            case .loadingSaved:
                SummaryMessageRow(systemImage: "clock", message: "Loading saved summary...")
            case .transcribing:
                SummaryMessageRow(systemImage: "waveform", message: "Transcribing available audio tracks...")
            case .recognizingScreen:
                SummaryMessageRow(systemImage: "text.viewfinder", message: "Extracting text from screen changes...")
            case .summarizing:
                SummaryMessageRow(systemImage: "text.magnifyingglass", message: "Generating summary...")
            case let .summaryProgress(progress):
                SummaryMessageRow(systemImage: "text.magnifyingglass", message: progress.message)
            case .summarized:
                EmptyView()
            case .cancelled:
                SummaryMessageRow(systemImage: "stop.circle", message: "キャンセルしました。保存済みの結果は保持されています。")
            case let .unavailable(message):
                SummaryMessageRow(systemImage: "exclamationmark.circle", message: message)
            case let .failed(message):
                SummaryMessageRow(systemImage: "xmark.circle", message: message)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func summaryIdleMessage(for item: RecordingLibraryItem) -> (systemImage: String, message: String) {
        if !item.hasTranscribableAudio {
            return ("exclamationmark.triangle", "No audio track is available.")
        }

        return ("text.badge.plus", "No summary saved yet.")
    }

    private func fileStatus(_ item: RecordingLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files")
                .font(.headline)

            VStack(spacing: 0) {
                LibraryFileStatusRow(
                    title: "Mixdown",
                    url: item.mixdownURL,
                    exists: item.fileExistence.mixdownExists,
                    isRequired: true,
                    missingStatusText: item.canRemix ? "Needs mix" : "Missing"
                )
                Divider()
                LibraryFileStatusRow(
                    title: "System Audio",
                    url: item.systemAudioURL,
                    exists: item.fileExistence.systemAudioExists,
                    isRequired: false
                )
                Divider()
                LibraryFileStatusRow(
                    title: "Microphone",
                    url: item.microphoneURL,
                    exists: item.fileExistence.microphoneExists,
                    isRequired: false
                )
                Divider()
                LibraryFileStatusRow(
                    title: "Screen Recording",
                    url: item.screenCaptureURL,
                    exists: item.fileExistence.screenCaptureExists,
                    isRequired: false
                )
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
    }
}

private struct MeetingSummaryView: View {
    let summary: MeetingSummary
    let transcript: TranscriptResult?
    let seek: (Double) -> Void

    var body: some View {
        let catalog = transcript.map(SummaryEvidenceCatalog.init)
        VStack(alignment: .leading, spacing: 16) {
            if let generation = summary.generation {
                Text(generation.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if summary.generation?.templateApplied != false, let templateName = summary.templateName {
                Label(templateName, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(summary.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            evidenceView(summary.evidenceIDs, catalog: catalog)

            if !summary.topics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Topics")
                        .font(.subheadline.weight(.semibold))

                    ForEach(summary.topics) { topic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.title)
                                .font(.callout.weight(.medium))

                            if let detail = topic.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            evidenceView(topic.evidenceIDs, catalog: catalog)
                        }
                    }
                }
            }

            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action Items")
                        .font(.subheadline.weight(.semibold))

                    ForEach(summary.actionItems) { actionItem in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(actionItem.title)
                                    .font(.callout.weight(.medium))

                                HStack(spacing: 8) {
                                    if let owner = actionItem.owner {
                                        Label(owner, systemImage: "person")
                                    }

                                    if let dueDateText = actionItem.dueDateText {
                                        Label(dueDateText, systemImage: "calendar")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                evidenceView(actionItem.evidenceIDs, catalog: catalog)
                            }
                        }
                    }
                }
            }
        }
    }

    private func evidenceView(_ ids: [String]?, catalog: SummaryEvidenceCatalog?) -> some View {
        SummaryEvidenceView(ids: ids, fingerprint: summary.evidenceInputFingerprint,
                            catalog: catalog, seek: seek)
    }
}

private struct SummaryMessageRow: View {
    let systemImage: String
    let message: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LibraryFileStatusRow: View {
    let title: String
    let url: URL?
    let exists: Bool
    let isRequired: Bool
    var missingStatusText: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))

                Text(fileText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(13)
    }

    private var fileText: String {
        guard let url else {
            return isRequired ? "Required file was not found" : "No source track"
        }

        return url.lastPathComponent
    }

    private var statusImage: String {
        exists ? "checkmark.circle.fill" : "xmark.circle"
    }

    private var statusText: String {
        if exists {
            return "Available"
        }

        return missingStatusText ?? (isRequired ? "Missing" : "Not saved")
    }

    private var statusColor: Color {
        exists ? .green : (isRequired ? .red : .secondary)
    }
}

private struct LibraryStatusView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

