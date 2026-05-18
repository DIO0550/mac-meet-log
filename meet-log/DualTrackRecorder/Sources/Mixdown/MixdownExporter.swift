import AVFoundation
import Foundation

struct MixdownExporter: MixdownExporting {
    func export(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        destinationURL: URL
    ) async throws -> URL {
        let inputURLs = [systemAudioURL, microphoneURL].compactMap { $0 }

        guard !inputURLs.isEmpty else {
            throw RecorderError.mixdownFailed("No source tracks were available for mixdown.")
        }

        do {
            try removeExistingFile(at: destinationURL)

            if inputURLs.count == 1, let sourceURL = inputURLs.first {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            }

            let composition = AVMutableComposition()

            for inputURL in inputURLs {
                try await insertAudio(from: inputURL, into: composition)
            }

            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw RecorderError.mixdownFailed("Could not create mixdown export session.")
            }

            exportSession.outputURL = destinationURL
            exportSession.outputFileType = .m4a
            exportSession.shouldOptimizeForNetworkUse = false

            try await export(exportSession)
            return destinationURL
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.mixdownFailed("Could not export mixdown: \(error.localizedDescription)")
        }
    }

    private func insertAudio(from url: URL, into composition: AVMutableComposition) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        guard let sourceTrack = tracks.first else {
            throw RecorderError.mixdownFailed("Source track does not contain audio: \(url.lastPathComponent)")
        }

        let duration = try await asset.load(.duration)

        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.mixdownFailed("Could not create mixdown track.")
        }

        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )
    }

    private func export(_ exportSession: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportSession.error?.localizedDescription ?? "Export was cancelled."
                    continuation.resume(throwing: RecorderError.mixdownFailed(message))
                default:
                    continuation.resume(throwing: RecorderError.mixdownFailed("Export ended in an unexpected state."))
                }
            }
        }
    }

    private func removeExistingFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }
}
