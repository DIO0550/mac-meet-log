import AVFoundation
import AVKit
import SwiftUI

struct MeetingPlaybackView: View {
    @ObservedObject var controller: MeetingPlaybackController
    let source: PlaybackSource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback").font(.headline)
            if controller.isLoading {
                ProgressView("素材を読み込んでいます…")
            }
            if controller.hasVideo {
                PlaybackVideoSurface(player: controller.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxHeight: 320)
            }
            HStack {
                Button(action: controller.toggle) {
                    Label(controller.isPlaying ? "Pause" : "Play",
                          systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                Slider(value: Binding(
                    get: { controller.position },
                    set: { controller.seek(to: $0) }
                ), in: 0...max(controller.duration, 0.001))
                .accessibilityLabel("再生位置")
                Picker("速度", selection: Binding(get: { controller.speed }, set: controller.setSpeed)) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .frame(width: 115)
            }
            .disabled(!controller.canPlay)
            Text("\(PlaybackTimeline.label(controller.position)) / \(PlaybackTimeline.label(controller.duration))")
                .font(.caption.monospacedDigit())
            Text(controller.availability)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = controller.errorMessage {
                Text(message).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task(id: source) {
            await controller.load(source)
        }
        .onDisappear {
            controller.stop()
        }
    }
}

/// Transport controls live above so native video controls cannot bypass seek/rate state.
private struct PlaybackVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

struct PlaybackTimestampButton: View {
    let title: String
    let seconds: Double
    var seek: ((Double) -> Void)?

    var body: some View {
        Button {
            seek?(seconds)
        } label: {
            Text(title).monospacedDigit()
        }
        .buttonStyle(.link)
        .disabled(seek == nil || !seconds.isFinite)
        .help("この時刻から再生")
    }
}
