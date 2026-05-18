import DualTrackRecorder
import SwiftUI

struct RecorderControls: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 16) {
            sourceToggles
            commandButtons
        }
    }

    private var sourceToggles: some View {
        HStack(spacing: 12) {
            SourceToggleButton(
                title: "System",
                systemImage: "speaker.wave.2.fill",
                isOn: viewModel.sources.systemAudioEnabled,
                isDisabled: !viewModel.canEditSources
            ) {
                viewModel.setSystemAudioEnabled(!viewModel.sources.systemAudioEnabled)
            }

            SourceToggleButton(
                title: "Mic",
                systemImage: "mic.fill",
                isOn: viewModel.sources.microphoneEnabled,
                isDisabled: !viewModel.canEditSources
            ) {
                viewModel.setMicrophoneEnabled(!viewModel.sources.microphoneEnabled)
            }
        }
    }

    @ViewBuilder
    private var commandButtons: some View {
        if viewModel.isRecording {
            HStack(spacing: 12) {
                SecondaryRecorderButton(title: "Pause", systemImage: "pause.fill", action: viewModel.pause)
                StopRecorderButton(action: viewModel.stop)
            }
        } else if viewModel.isPaused {
            HStack(spacing: 12) {
                SecondaryRecorderButton(title: "Resume", systemImage: "play.fill", action: viewModel.resume)
                StopRecorderButton(action: viewModel.stop)
            }
        } else {
            Button(action: viewModel.start) {
                Label(startTitle, systemImage: "record.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!viewModel.canStart)
            .help(viewModel.sources.hasAnyEnabledSource ? "Start recording" : "Choose at least one source")
        }
    }

    private var startTitle: String {
        if viewModel.isPreparing {
            return "Preparing"
        }

        if viewModel.isFinalizing {
            return "Saving"
        }

        return "Start Recording"
    }
}

private struct SourceToggleButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(.callout.weight(.medium))

                Spacer(minLength: 0)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? .green : .secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isOn ? Color.accentColor.opacity(0.34) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.58 : 1)
        .help(isOn ? "Turn \(title) off" : "Turn \(title) on")
    }
}

private struct SecondaryRecorderButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.bordered)
    }
}

private struct StopRecorderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Stop", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}
