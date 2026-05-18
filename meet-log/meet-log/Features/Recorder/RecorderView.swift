//
//  RecorderView.swift
//  meet-log
//
//  Created by DIO on 2026/05/16.
//

import DualTrackRecorder
import SwiftUI

struct RecorderView: View {
    @StateObject private var viewModel: RecorderViewModel

    @MainActor
    init() {
        self.init(viewModel: RecorderViewModel())
    }

    @MainActor
    init(viewModel: @autoclosure @escaping () -> RecorderViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            timer

            RecorderLevelView(
                level: viewModel.level,
                waveform: viewModel.waveform,
                isActive: viewModel.isRecording
            )

            if let error = viewModel.presentedError {
                RecorderErrorBanner(
                    error: error,
                    settingsAction: viewModel.openMicrophoneSettings,
                    dismissAction: viewModel.dismissError
                )
            }

            Spacer(minLength: 0)

            if let completion = viewModel.completion {
                RecordingCompleteView(
                    completion: completion,
                    revealAction: viewModel.revealCompletionInFinder,
                    dismissAction: viewModel.dismiss
                )
            } else {
                RecorderControls(viewModel: viewModel)
            }
        }
        .padding(22)
        .frame(width: 420, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.secondary.opacity(0.16))
                    .frame(width: 12, height: 12)

                if viewModel.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 8)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("meet-log")
                    .font(.headline)

                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var timer: some View {
        VStack(spacing: 6) {
            Text(viewModel.elapsed.recorderDisplayString)
                .font(.system(size: 70, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Text(sourceSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 8)
    }

    private var sourceSummary: String {
        switch (viewModel.sources.systemAudioEnabled, viewModel.sources.microphoneEnabled) {
        case (true, true):
            "System audio + microphone"
        case (true, false):
            "System audio only"
        case (false, true):
            "Microphone only"
        case (false, false):
            "No source selected"
        }
    }
}

private struct RecorderErrorBanner: View {
    let error: RecorderErrorPresentation
    let settingsAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title)
                        .font(.callout.weight(.semibold))

                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack {
                if error.recoveryAction == .microphoneSettings {
                    Button("Open Settings", action: settingsAction)
                }

                Spacer(minLength: 0)

                Button("Dismiss", action: dismissAction)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview {
    RecorderView()
}
