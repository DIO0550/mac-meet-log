import AVFoundation
import Foundation

/// Independently closed AAC files survive even when the main M4A has no final header.
/// Only renamed, completed files are candidates for automatic recovery.
final class RecoveryAudioSegments {
    private let directory: URL
    private var file: AVAudioFile?
    private var partialURL: URL?
    private var segmentStart: TimeInterval = 0
    private var segmentDuration: TimeInterval = 0

    init(trackURL: URL) {
        directory = trackURL.deletingPathExtension().appendingPathExtension("segments")
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        if file == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).partial.m4a")
            partialURL = url
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: Int(buffer.format.channelCount),
                AVEncoderBitRateKey: 128_000
            ], commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        }
        try file?.write(from: buffer)
        segmentDuration += Double(buffer.frameLength) / buffer.format.sampleRate
        if segmentDuration >= 5 { try close() }
    }

    func close() throws {
        guard let partialURL else { return }
        file = nil // AVAudioFile finalizes the container on release.
        let end = segmentStart + segmentDuration
        let name = String(format: "%020lld-%020lld.m4a",
                          Int64((segmentStart * 1_000_000).rounded()), Int64((end * 1_000_000).rounded()))
        try FileManager.default.moveItem(at: partialURL, to: directory.appendingPathComponent(name))
        self.partialURL = nil
        segmentStart = end
        segmentDuration = 0
    }
}
