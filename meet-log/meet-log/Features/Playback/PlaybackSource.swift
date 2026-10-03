import Foundation

struct PlaybackSource: Hashable {
    let audioURLs: [URL]
    let videoURL: URL?

    init(audioURLs: [URL], videoURL: URL? = nil) {
        self.audioURLs = audioURLs
        self.videoURL = videoURL
    }

    init(item: RecordingLibraryItem) {
        if item.hasUsableMixdown {
            audioURLs = [item.mixdownURL]
        } else {
            audioURLs = [item.existingSystemAudioURL, item.existingMicrophoneURL].compactMap { $0 }
        }
        videoURL = item.screenCaptureURL
    }
}

nonisolated enum PlaybackTimeline {
    static func position(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else {
            return nil
        }
        return min(max(seconds, 0), duration)
    }

    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
            return "--:--"
        }
        let whole = Int(seconds)
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }
}
