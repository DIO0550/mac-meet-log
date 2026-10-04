import AppKit
import SwiftUI

struct RecorderMenuBarLabel: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        let status = viewModel.menuBarStatus
        Label("\(status.text) \(viewModel.elapsed.recorderDisplayString)", systemImage: status.systemImage)
            .monospacedDigit()
            .accessibilityLabel("meet-log, \(status.text), \(viewModel.elapsed.recorderDisplayString)")
            .help("meet-log: \(status.text)")
    }
}

struct RecorderMenuBarView: View {
    @ObservedObject var viewModel: RecorderViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(viewModel.menuBarStatus.text, systemImage: viewModel.menuBarStatus.systemImage)
                Spacer()
                Text(viewModel.elapsed.recorderDisplayString).monospacedDigit()
                    .accessibilityLabel("Elapsed recording time")
                    .accessibilityValue(viewModel.elapsed.recorderDisplayString)
            }
            .font(.headline)

            if viewModel.isTestRecording && (viewModel.isRecording || viewModel.isStarting) {
                Text("Testing inputs (5 seconds)").font(.caption)
            }

            recordingControls

            if viewModel.isRecording || viewModel.isPaused {
                TextField("Note at the current time", text: $noteText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Timestamped note")
                    .accessibilityHint("Press Return to save a note at the current recording time")
                    .onSubmit(addNote)
                    .disabled(!viewModel.canAddNote)
                Button("Add Note", action: addNote)
                    .disabled(!viewModel.canAddNote || noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if viewModel.hasUnsavedNotes {
                Text("Notes have not been saved.").foregroundStyle(.red)
                Button("Retry Saving Notes", action: viewModel.saveNotes)
                    .disabled(viewModel.isTerminating)
            }

            if let error = viewModel.presentedError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.title).font(.callout.bold())
                    Text(error.message).font(.caption)
                    HStack {
                        if error.recoveryAction != nil {
                            Button("Open Settings", action: viewModel.openRelevantSettings)
                        }
                        Button("Dismiss Error", action: viewModel.dismissError)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
            }

            if let warning = viewModel.completion?.warningMessage {
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(viewModel.healthWarnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Open Main Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)
            Text("Closing the window keeps recording running.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Quit meet-log") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var recordingControls: some View {
        HStack {
            Button("Start", action: viewModel.start)
                .disabled(!viewModel.canStart)
                .keyboardShortcut("r", modifiers: .command)
            if viewModel.isPaused {
                Button("Resume", action: viewModel.resume)
                    .disabled(!viewModel.canResume)
                    .keyboardShortcut("p", modifiers: .command)
            } else {
                Button("Pause", action: viewModel.pause)
                    .disabled(!viewModel.canPause)
                    .keyboardShortcut("p", modifiers: .command)
            }
            Button("Stop", action: viewModel.stop)
                .disabled(!viewModel.canStop)
                .keyboardShortcut(".", modifiers: .command)
        }
        .disabled(viewModel.isTerminating)
    }

    private func addNote() {
        if viewModel.addNote(noteText) { noteText = "" }
    }
}

extension RecorderViewModel {
    var menuBarStatus: RecordingMenuBarStatus {
        RecordingMenuBarStatus(state: state, isStarting: isStarting,
                              isStopping: isStopping || isTerminating,
                              hasError: presentedError != nil || completion?.warningMessage != nil)
    }
}
