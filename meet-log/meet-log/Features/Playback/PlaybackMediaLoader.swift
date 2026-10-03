import AVFoundation
import Foundation

/// Keep imported files accessible for the entire lifetime of their player item.
final class PlaybackFileAccess {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit {
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct PlaybackMedia {
    let composition: AVMutableComposition
    let hasVideo: Bool
    let availability: String
    let access: PlaybackFileAccess
}

@MainActor
protocol PlaybackMediaLoading {
    func load(_ source: PlaybackSource) async throws -> PlaybackMedia
}

@MainActor
struct PlaybackMediaLoader: PlaybackMediaLoading {
    func load(_ source: PlaybackSource) async throws -> PlaybackMedia {
        let access = PlaybackFileAccess(urls: source.audioURLs + [source.videoURL].compactMap { $0 })
        let composition = AVMutableComposition()
        var messages: [String] = []
        var audioCount = 0
        for url in source.audioURLs {
            do {
                try await insert(url, type: .audio, into: composition)
                audioCount += 1
            } catch {
                messages.append("音声を利用できません（\(url.lastPathComponent)）: \(error.localizedDescription)")
            }
        }
        var hasVideo = false
        if let url = source.videoURL {
            do {
                try await insert(url, type: .video, into: composition)
                hasVideo = true
            } catch {
                messages.append("画面動画を利用できません: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        guard audioCount > 0 || hasVideo else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if audioCount == 0 {
            messages.insert("画面のみ再生できます。音声はありません。", at: 0)
        }
        if !hasVideo {
            messages.insert("音声のみ再生できます。画面動画はありません。", at: 0)
        }
        if audioCount > 0, hasVideo {
            messages.insert("音声と画面を同期再生します。", at: 0)
        }
        return PlaybackMedia(
            composition: composition,
            hasVideo: hasVideo,
            availability: messages.joined(separator: "\n"),
            access: access
        )
    }

    private func insert(_ url: URL, type: AVMediaType, into composition: AVMutableComposition) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: type).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = try await track.load(.timeRange)
        guard range.start.seconds.isFinite, range.start.seconds >= 0,
              range.duration.seconds.isFinite, range.duration.seconds > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let transform = try await track.load(.preferredTransform)
        try Task.checkCancellation()
        guard let destination = composition.addMutableTrack(
            withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            // Preserve the recorded active-time timestamps, including any leading gap.
            // Both media types share one AVPlayer clock; pauses are already removed on capture.
            try destination.insertTimeRange(range, of: track, at: range.start)
            destination.preferredTransform = transform
        } catch {
            composition.removeTrack(destination)
            throw error
        }
    }
}
