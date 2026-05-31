//
//  RecorderView.swift
//  meet-log
//
//  Created by DIO on 2026/05/16.
//

import DualTrackRecorder
import AppKit
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
        VStack(spacing: 14) {
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
        .padding(18)
        .frame(width: 420, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppHeaderIcon(isRecording: viewModel.isRecording)

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
        .padding(.top, 4)
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

private struct AppHeaderIcon: View {
    let isRecording: Bool

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .overlay {
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        }
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
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
