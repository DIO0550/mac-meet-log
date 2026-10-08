import DualTrackRecorder
import Foundation

struct PlaybackSource: Hashable {
    let audioURLs: [URL]
    let videoURL: URL?

    var recordingURL: URL? {
        guard let url = audioURLs.first ?? videoURL else { return nil }
        if RecordingLibraryItem.mixdownStem(from: url) != nil {
            return url
        }
        guard let stem = RecordingLibraryItem.stem(fromFileName: url.lastPathComponent) else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)_mix.m4a")
    }

    init(audioURLs: [URL], videoURL: URL? = nil) {
        self.audioURLs = audioURLs
        self.videoURL = videoURL
    }

    init(completion: RecordingCompletion) {
        if let mixdownURL = completion.mixdown.url {
            audioURLs = [mixdownURL]
        } else {
            audioURLs = [completion.systemAudioURL, completion.microphoneURL].compactMap { $0 }
        }
        videoURL = completion.screenCaptureURL
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
        if whole < 3600 {
            return String(format: "%02d:%02d", whole / 60, whole % 60)
        }
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }
}
