import DualTrackRecorder
import SwiftUI

struct RecorderControls: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 12) {
            sourceToggles
            sourceAccessButtons
            microphonePicker
            screenCapturePicker
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

            SourceToggleButton(
                title: "Screen",
                systemImage: "rectangle.inset.filled.and.person.filled",
                isOn: viewModel.sources.screenCaptureEnabled,
                isDisabled: !viewModel.canEditSources
            ) {
                viewModel.setScreenCaptureEnabled(!viewModel.sources.screenCaptureEnabled)
            }
        }
    }

    private var sourceAccessButtons: some View {
        HStack(spacing: 8) {
            if viewModel.shouldShowSystemAudioPermissionRequest {
                SourceAccessButton(
                    title: systemAudioAccessTitle,
                    systemImage: "waveform.badge.magnifyingglass",
                    isRequesting: viewModel.isRequestingSystemAudioPermission,
                    isDisabled: !viewModel.canRequestSystemAudioPermission,
                    action: viewModel.requestSystemAudioPermission
                )
            }

            if viewModel.shouldShowMicrophonePermissionRequest {
                SourceAccessButton(
                    title: microphoneAccessTitle,
                    systemImage: "mic.badge.plus",
                    isRequesting: viewModel.isRequestingMicrophonePermission,
                    isDisabled: !viewModel.canRequestMicrophonePermission,
                    action: viewModel.requestMicrophonePermission
                )
            }

            if viewModel.shouldShowScreenCapturePermissionRequest {
                SourceAccessButton(
                    title: screenCaptureAccessTitle,
                    systemImage: "rectangle.on.rectangle.badge.person.crop",
                    isRequesting: viewModel.isRequestingScreenCapturePermission,
                    isDisabled: !viewModel.canRequestScreenCapturePermission,
                    action: viewModel.requestScreenCapturePermission
                )
            }
        }
    }

    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Microphone", systemImage: "mic.fill")
                    .font(.callout.weight(.medium))

                Spacer(minLength: 0)

                if viewModel.isSwitchingMicrophoneInput {
                    ProgressView()
                        .controlSize(.small)

                    Text("Switching")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                "Microphone",
                selection: Binding(
                    get: { viewModel.selectedMicrophoneDeviceID ?? "" },
                    set: { newValue in
                        viewModel.selectMicrophoneDevice(id: newValue.isEmpty ? nil : newValue)
                    }
                )
            ) {
                Text(viewModel.defaultMicrophoneDeviceDisplayName)
                    .tag("")

                ForEach(viewModel.microphoneDevices) { device in
                    Text(device.displayName)
                        .tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!viewModel.canSelectMicrophoneInput)
            .help(microphonePickerHelp)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .opacity(viewModel.sources.microphoneEnabled ? 1 : 0.58)
    }

    @ViewBuilder
    private var screenCapturePicker: some View {
        if viewModel.sources.screenCaptureEnabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Screen capture", systemImage: "rectangle.on.rectangle")
                        .font(.callout.weight(.medium))

                    Spacer(minLength: 0)

                    if viewModel.isLoadingScreenCaptureTargets {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Picker(
                    "Screen capture",
                    selection: Binding(
                        get: { viewModel.selectedScreenCaptureTargetID ?? "" },
                        set: viewModel.selectScreenCaptureTarget
                    )
                ) {
                    if viewModel.screenCaptureTargets.isEmpty {
                        Text("No capture target available").tag("")
                    }

                    ForEach(viewModel.screenCaptureTargets) { target in
                        Text(target.detail.isEmpty ? target.name : "\(target.name) — \(target.detail)")
                            .tag(target.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!viewModel.canEditSources || viewModel.screenCaptureTargets.isEmpty)

                Text("15 fps · up to 1920×1080 · no live preview")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
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

    private var systemAudioAccessTitle: String {
        if viewModel.isRequestingSystemAudioPermission {
            return "Requesting System"
        }

        return "System Access"
    }

    private var microphoneAccessTitle: String {
        if viewModel.isRequestingMicrophonePermission {
            return "Requesting Mic"
        }

        if viewModel.microphonePermissionState == .blocked {
            return "Mic Settings"
        }

        return "Mic Access"
    }

    private var screenCaptureAccessTitle: String {
        if viewModel.isRequestingScreenCapturePermission {
            return "Requesting Screen"
        }

        if viewModel.screenCapturePermissionState == .blocked {
            return "Screen Settings"
        }

        return "Screen Access"
    }

    private var microphonePickerHelp: String {
        if viewModel.sources.microphoneEnabled == false {
            return "Turn on microphone recording to choose an input"
        }

        if viewModel.isSwitchingMicrophoneInput {
            return "Microphone input is switching"
        }

        if viewModel.isFinalizing {
            return "Recording is saving"
        }

        return "Choose microphone input"
    }
}

private struct SourceAccessButton: View {
    let title: String
    let systemImage: String
    let isRequesting: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))

                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                if isRequesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .help(title)
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
