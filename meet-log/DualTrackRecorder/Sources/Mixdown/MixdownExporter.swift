import AVFoundation
import Foundation

struct MixdownExporter: MixdownExporting, @unchecked Sendable {
    private let pipeline: AudioMixdownPipeline
    private let fileManager: FileManager

    init(
        pipeline: AudioMixdownPipeline = AudioMixdownPipeline(),
        fileManager: FileManager = .default
    ) {
        self.pipeline = pipeline
        self.fileManager = fileManager
    }

    func export(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        destinationURL: URL
    ) async throws -> URL {
        let inputURLs = [systemAudioURL, microphoneURL].compactMap { $0 }

        guard !inputURLs.isEmpty else {
            throw RecorderError.mixdownFailed("No source tracks were available for mixdown.")
        }

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".mixing-\(UUID().uuidString).m4a")

        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        do {
            try await pipeline.export(inputURLs: inputURLs, outputURL: stagingURL)
            try await validateAudio(at: stagingURL)
            try publish(stagingURL: stagingURL, destinationURL: destinationURL)
            return destinationURL
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.mixdownFailed(
                await AudioMixdownDiagnostics.describe(error: error, inputURLs: inputURLs)
            )
        }
    }

    private func validateAudio(at url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.fileFormat
        let formatID = fileFormat.streamDescription.pointee.mFormatID
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)

        guard tracks.count == 1,
              duration > .zero,
              formatID == kAudioFormatMPEG4AAC,
              fileFormat.sampleRate == AudioMixdownPipeline.Configuration.canonical.sampleRate,
              fileFormat.channelCount == AVAudioChannelCount(
                  AudioMixdownPipeline.Configuration.canonical.channelCount
              ) else {
            throw MixdownValidationError.nonCanonicalOutput(
                formatID: formatID,
                sampleRate: fileFormat.sampleRate,
                channelCount: fileFormat.channelCount,
                duration: duration
            )
        }

        guard let decodeFormat = AVAudioFormat(
            standardFormatWithSampleRate: AudioMixdownPipeline.Configuration.canonical.sampleRate,
            channels: AVAudioChannelCount(AudioMixdownPipeline.Configuration.canonical.channelCount)
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: 1_024) else {
            throw MixdownValidationError.couldNotAllocateProbeBuffer
        }

        try file.read(into: buffer, frameCount: 1_024)

        guard buffer.frameLength > 0 else {
            throw MixdownValidationError.couldNotDecodeFirstBuffer
        }
    }

    private func publish(stagingURL: URL, destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return
        }

        let backupName = ".mix-backup-\(UUID().uuidString).m4a"
        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(backupName)

        do {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: []
            )
            try? fileManager.removeItem(at: backupURL)
        } catch let replacementError {
            var restorationError: Error?

            if !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                do {
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                } catch {
                    restorationError = error
                }
            } else if !fileManager.fileExists(atPath: destinationURL.path) {
                restorationError = MixdownPublicationError.missingBackup(backupURL)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }

            throw MixdownPublicationError.replacementFailed(
                replacement: replacementError,
                restoration: restorationError,
                retainedBackupURL: restorationError == nil ? nil : backupURL
            )
        }
    }
}

private enum MixdownValidationError: Error {
    case nonCanonicalOutput(
        formatID: AudioFormatID,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        duration: CMTime
    )
    case couldNotAllocateProbeBuffer
    case couldNotDecodeFirstBuffer
}

enum MixdownPublicationError: Error {
    case missingBackup(URL)
    case replacementFailed(
        replacement: Error,
        restoration: Error?,
        retainedBackupURL: URL?
    )

    var diagnosticDescription: String {
        switch self {
        case let .missingBackup(url):
            return "publication backup missing at \(url.path)"
        case let .replacementFailed(replacement, restoration, retainedBackupURL):
            var components = [
                "replace={\(AudioMixdownDiagnostics.errorChain(replacement))}"
            ]

            if let restoration {
                components.append("restore={\(AudioMixdownDiagnostics.errorChain(restoration))}")
            }

            if let retainedBackupURL {
                components.append("retainedBackup=\(retainedBackupURL.path)")
            }

            return components.joined(separator: ", ")
        }
    }
}
