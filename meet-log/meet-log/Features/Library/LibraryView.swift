import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    let recorderAction: () -> Void

    @MainActor
    init(recorderAction: @escaping () -> Void) {
        self.init(viewModel: LibraryViewModel(), recorderAction: recorderAction)
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
        }
        .frame(minWidth: 920, idealWidth: 980, minHeight: 580, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: recorderAction) {
                Label("Recorder", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(.title3.weight(.semibold))

                Text("Saved mixdowns from ~/Music/meet-log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: viewModel.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
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
            HStack {
                Text("\(viewModel.items.count) recordings")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            List(selection: $viewModel.selectedID) {
                ForEach(viewModel.items) { item in
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
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct LibraryItemRow: View {
    let item: RecordingLibraryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.hasMissingFiles ? "waveform.badge.exclamationmark" : "waveform")
                .foregroundStyle(item.hasMissingFiles ? .orange : .blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

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
}

private struct LibraryDetailPane: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if let item = viewModel.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleBlock(item)
                    actions
                    fileStatus(item)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
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

                if item.hasMissingFiles {
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

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.togglePlayback) {
                Label(
                    viewModel.isPlayingSelectedItem ? "Stop" : "Play Mixdown",
                    systemImage: viewModel.isPlayingSelectedItem ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            Button(action: viewModel.revealSelectedItemInFinder) {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            if case let .failed(message) = viewModel.playbackState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
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
                    isRequired: true
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
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
    }
}

private struct LibraryFileStatusRow: View {
    let title: String
    let url: URL?
    let exists: Bool
    let isRequired: Bool

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

        return isRequired ? "Missing" : "Not saved"
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
