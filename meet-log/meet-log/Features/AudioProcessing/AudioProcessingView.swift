import SwiftUI
import UniformTypeIdentifiers

struct AudioProcessingView: View {
    @StateObject private var viewModel: AudioProcessingViewModel
    @State private var isDropTargeted = false
    let recorderAction: () -> Void

    @MainActor
    init(recorderAction: @escaping () -> Void) {
        self.init(
            viewModel: AudioProcessingViewModel(),
            recorderAction: recorderAction
        )
    }

    @MainActor
    init(
        viewModel: @autoclosure @escaping () -> AudioProcessingViewModel,
        recorderAction: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.recorderAction = recorderAction
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    importSection
                    stateSection
                    transcriptSection
                    summarySection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $viewModel.isImporterPresented,
            allowedContentTypes: AudioImportAllowedContentTypes.values,
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleImporterResult(firstSelectedURL(from: result))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: recorderAction) {
                Label("Recorder", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 2) {
                Text("Process Audio")
                    .font(.title3.weight(.semibold))

                Text("Transcribe and summarize an audio file on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio File")
                        .font(.headline)

                    if let selectedFileName = viewModel.selectedFileName {
                        Text(selectedFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("MP3, M4A, or WAV")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Button(action: viewModel.presentImporter) {
                    Label("Choose", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }

            dropTarget
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private var dropTarget: some View {
        HStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            Text(isDropTargeted ? "Drop to start processing" : "Drop an audio file here")
                .font(.callout.weight(.medium))
                .foregroundStyle(isDropTargeted ? .primary : .secondary)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            Color.accentColor.opacity(isDropTargeted ? 0.12 : 0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isDropTargeted ? 0.55 : 0.2),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch viewModel.state {
        case .idle:
            StatusRow(
                systemImage: "waveform",
                title: "Ready",
                message: "Choose an audio file to begin."
            )
        case .loading:
            StatusRow(
                systemImage: "clock",
                title: "Reading audio",
                message: "Validating the selected file.",
                isBusy: true,
                cancelAction: { viewModel.cancel() }
            )
        case let .transcribing(item, _):
            StatusRow(
                systemImage: "text.viewfinder",
                title: "Transcribing",
                message: "\(item.durationText) · \(item.byteSizeText)",
                isBusy: true,
                cancelAction: { viewModel.cancel() }
            )
        case .summarizing(_, _):
            StatusRow(
                systemImage: "text.magnifyingglass",
                title: "Summarizing",
                message: "Transcript is ready. Generating meeting notes.",
                isBusy: true,
                cancelAction: { viewModel.cancel() }
            )
        case .completed(_, _, _):
            StatusRow(
                systemImage: "checkmark.circle.fill",
                title: "Complete",
                message: "Transcript output is ready."
            )
        case let .failed(_, error, transcript):
            StatusRow(
                systemImage: "xmark.circle",
                title: transcript == nil ? "Processing failed" : "Summary failed",
                message: error.localizedDescription,
                retryAction: { viewModel.retry() },
                chooseAction: { viewModel.presentImporter() }
            )
        case .cancelled(_):
            StatusRow(
                systemImage: "pause.circle",
                title: "Cancelled",
                message: "Processing stopped before completion.",
                retryAction: { viewModel.retry() },
                chooseAction: { viewModel.presentImporter() }
            )
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let transcriptText = viewModel.transcriptText {
            OutputSection(
                title: "Transcript",
                systemImage: "quote.bubble",
                actionTitle: "Copy",
                actionSystemImage: "doc.on.doc",
                action: viewModel.copyTranscript
            ) {
                Text(transcriptText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        switch viewModel.state {
        case let .completed(_, _, result):
            switch result {
            case let .summarized(summary):
                OutputSection(
                    title: "Summary",
                    systemImage: "text.badge.checkmark",
                    actionTitle: "Copy",
                    actionSystemImage: "doc.on.doc",
                    action: viewModel.copySummary
                ) {
                    MeetingSummaryResultView(summary: summary)
                }
            case let .unavailable(reason):
                StatusRow(
                    systemImage: "exclamationmark.circle",
                    title: "Summary unavailable",
                    message: reason.localizedDescription
                )
            case .failed:
                EmptyView()
            }
        case .idle, .loading, .transcribing, .summarizing, .failed, .cancelled:
            EmptyView()
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadObject(ofClass: NSURL.self) { item, _ in
            guard let url = item as? URL else {
                return
            }

            Task { @MainActor in
                viewModel.process(audioURL: url)
            }
        }

        return true
    }
}

private struct StatusRow: View {
    let systemImage: String
    let title: String
    let message: String
    var isBusy = false
    var cancelAction: (() -> Void)?
    var retryAction: (() -> Void)?
    var chooseAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let cancelAction {
                    Button(action: cancelAction) {
                        Label("Cancel", systemImage: "xmark")
                    }
                }

                if let retryAction {
                    Button(action: retryAction) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }

                if let chooseAction {
                    Button(action: chooseAction) {
                        Label("Choose", systemImage: "folder")
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct OutputSection<Content: View>: View {
    let title: String
    let systemImage: String
    let actionTitle: String
    let actionSystemImage: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Spacer(minLength: 0)

                Button(action: action) {
                    Label(actionTitle, systemImage: actionSystemImage)
                }
                .buttonStyle(.bordered)
            }

            content
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct MeetingSummaryResultView: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

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
                        }
                    }
                }
            }

            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action Items")
                        .font(.subheadline.weight(.semibold))

                    ForEach(summary.actionItems) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.callout.weight(.medium))

                            HStack(spacing: 8) {
                                if let owner = item.owner {
                                    Label(owner, systemImage: "person")
                                }

                                if let dueDateText = item.dueDateText {
                                    Label(dueDateText, systemImage: "calendar")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
