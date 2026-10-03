import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingPlaybackController: ObservableObject {
    static let supportedSpeeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasVideo = false
    @Published private(set) var availability = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var speed: Float = 1
    let player = AVPlayer()

    private let loader: any PlaybackMediaLoading
    private var media: PlaybackMedia?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var isSeeking = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?

    convenience init() {
        self.init(loader: PlaybackMediaLoader())
    }

    init(loader: any PlaybackMediaLoading) {
        self.loader = loader
    }

    var canPlay: Bool { duration > 0 && !isLoading && errorMessage == nil }

    func load(_ source: PlaybackSource) async {
        stop()
        let request = generation
        isLoading = true
        do {
            let loaded = try await loader.load(source)
            guard generation == request, !Task.isCancelled else {
                return
            }
            let length = loaded.composition.duration.seconds
            guard length.isFinite, length > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            media = loaded
            duration = length
            hasVideo = loaded.hasVideo
            availability = loaded.availability
            let item = AVPlayerItem(asset: loaded.composition)
            player.replaceCurrentItem(with: item)
            observe(item, generation: request)
            isLoading = false
        } catch {
            guard generation == request else {
                return
            }
            isLoading = false
            errorMessage = "再生できる素材がありません。ファイルやアクセス権を確認してください: \(error.localizedDescription)"
        }
    }

    func toggle() {
        guard canPlay else {
            return
        }
        if isPlaying {
            pause()
            return
        }
        if position >= duration {
            seek(to: 0, play: true)
            return
        }
        isPlaying = true
        if !isSeeking {
            player.playImmediately(atRate: speed)
        }
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func setSpeed(_ value: Float) {
        guard Self.supportedSpeeds.contains(value) else {
            return
        }
        speed = value
        if isPlaying, !isSeeking {
            player.playImmediately(atRate: value)
        }
    }

    func jump(to seconds: Double) {
        seek(to: seconds, play: true)
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard canPlay, let target = PlaybackTimeline.position(seconds, duration: duration) else {
            return
        }
        let request = UUID()
        seekGeneration = request
        isPlaying = (play || isPlaying) && target < duration
        isSeeking = true
        player.pause()
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.seekGeneration == request else {
                    return
                }
                self.isSeeking = false
                guard completed else {
                    self.pause()
                    return
                }
                if self.isPlaying {
                    self.player.playImmediately(atRate: self.speed)
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        seekGeneration = UUID()
        pause()
        isSeeking = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        media = nil
        position = 0
        duration = 0
        hasVideo = false
        isLoading = false
        availability = ""
        errorMessage = nil
    }

    private func observe(_ item: AVPlayerItem, generation request: UUID) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == request, !self.isSeeking,
                      let position = PlaybackTimeline.position(time.seconds, duration: self.duration) else {
                    return
                }
                self.position = position
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == request, !self.isSeeking else {
                    return
                }
                self.pause()
                self.position = self.duration
            }
        }
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else {
                return
            }
            let message = item.error?.localizedDescription ?? "素材を再生できません。"
            Task { @MainActor in
                guard let self, self.generation == request else {
                    return
                }
                self.pause()
                self.errorMessage = message
            }
        }
    }
}
