import AVFoundation
import Darwin
import Foundation

protocol AudioFileImporting: Sendable {
    nonisolated func importAudio(from url: URL) async throws -> AudioImportItem
}

struct AVAudioFileImporter: AudioFileImporting {
    private let supportedExtensions: Set<String>

    nonisolated init(supportedExtensions: Set<String> = ["mp3", "m4a", "wav"]) {
        self.supportedExtensions = supportedExtensions
    }

    nonisolated func importAudio(from url: URL) async throws -> AudioImportItem {
        let supportedExtensions = supportedExtensions
        return try await Task.detached(priority: .userInitiated) {
            try importAudioSynchronously(from: url, supportedExtensions: supportedExtensions)
        }.value
    }
}

nonisolated private func importAudioSynchronously(
    from url: URL,
    supportedExtensions: Set<String>
) throws -> AudioImportItem {
    let fileExtension = url.pathExtension.lowercased()
    guard supportedExtensions.contains(fileExtension) else {
        throw AudioImportError.unsupportedFormat(fileExtension)
    }

    let didStartAccessing = url.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    let byteSize = try fileSize(for: url)
    guard byteSize > 0 else {
        throw AudioImportError.emptyFile
    }

    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: url)
    } catch {
        throw AudioImportError.unreadable(error.localizedDescription)
    }

    let sampleRate = audioFile.fileFormat.sampleRate
    let frameCount = audioFile.length
    guard sampleRate.isFinite, sampleRate > 0, frameCount > 0 else {
        throw AudioImportError.metadataUnavailable("Duration is unavailable.")
    }

    let seconds = Double(frameCount) / sampleRate
    guard seconds.isFinite, seconds > 0 else {
        throw AudioImportError.metadataUnavailable("Duration is unavailable.")
    }

    return AudioImportItem(
        url: url,
        fileName: url.lastPathComponent,
        fileExtension: fileExtension,
        byteSize: byteSize,
        duration: duration(fromSeconds: seconds),
        channelCount: Int(audioFile.fileFormat.channelCount),
        sampleRate: sampleRate
    )
}

nonisolated private func fileSize(for url: URL) throws -> Int64 {
    do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    } catch {
        throw audioImportError(forResourceValueError: error)
    }
}

nonisolated private func audioImportError(forResourceValueError error: Error) -> AudioImportError {
    if isMissingFileError(error) {
        return .fileNotFound
    }

    if isPermissionError(error) {
        return .permissionDenied(error.localizedDescription)
    }

    return .unreadable(error.localizedDescription)
}

nonisolated private func isMissingFileError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
        return true
    }

    if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
        return true
    }

    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isMissingFileError(underlyingError)
    }

    return false
}

nonisolated private func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
        return true
    }

    if nsError.domain == NSPOSIXErrorDomain, [EACCES, EPERM].contains(Int32(nsError.code)) {
        return true
    }

    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isPermissionError(underlyingError)
    }

    return false
}

nonisolated private func duration(fromSeconds seconds: Double) -> Duration {
    .seconds(Int64(seconds.rounded(.down)))
        + .nanoseconds(Int64((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000_000).rounded()))
}
