import SwiftUI

struct AppRootView: View {
    enum Destination {
        case recorder
        case library
        case audioProcessing
    }

    @ObservedObject var recorderViewModel: RecorderViewModel
    @State private var destination: Destination = .recorder
    @ObservedObject private var settings = AppSettings.shared
    @State private var interrupted: [InterruptedRecording] = []
    @State private var showRecovery = false
    @State private var recoveryScanError: String?

    var body: some View {
        Group {
            switch destination {
            case .recorder:
                ZStack(alignment: .topTrailing) {
                    RecorderView(viewModel: recorderViewModel)

                    HStack(spacing: 10) {
                        if !interrupted.isEmpty {
                            Button { showRecovery = true } label: {
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .frame(width: 28, height: 28)
                            }
                            .help("未完了の録音を復旧")
                            .accessibilityLabel("未完了の録音を復旧")
                        }
                        Button {
                            destination = .audioProcessing
                        } label: {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("Process Audio")
                        .accessibilityLabel("Process Audio")

                        Button {
                            destination = .library
                        } label: {
                            Image(systemName: "books.vertical")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("Open Library")
                        .accessibilityLabel("Open Library")
                    }
                    .padding(14)
                }
                .frame(width: 420, height: 680)
            case .library:
                LibraryView {
                    destination = .recorder
                }
            case .audioProcessing:
                AudioProcessingView {
                    destination = .recorder
                }
            }
        }
        .task(id: settings.directoryRevision) {
            guard recorderViewModel.canEditSources else { return }
            let locations = settings.recoveryDirectories()
            var warnings = locations.warnings
            var sessions: [InterruptedRecording] = []
            for directory in locations.directories {
                do { sessions += try RecordingRecoveryStore.interrupted(in: directory) }
                catch { warnings.append("\(directory.path): \(error.localizedDescription)") }
            }
            interrupted = sessions
            showRecovery = !interrupted.isEmpty
            if !warnings.isEmpty { recoveryScanError = warnings.joined(separator: "\n") }
        }
        .sheet(isPresented: $showRecovery) {
            RecordingRecoveryView(sessions: interrupted) { destination = .library }
        }
        .alert("未完了の録音を確認できません", isPresented: Binding(
            get: { recoveryScanError != nil }, set: { if !$0 { recoveryScanError = nil } }
        )) {
            Button("OK") { recoveryScanError = nil }
        } message: {
            Text(recoveryScanError ?? "")
        }
    }
}
