import AVFoundation
import AudioToolbox
import Foundation

struct AudioMixdownPipeline {
    struct Configuration {
        let sampleRate: Double
        let channelCount: Int
        let bitRate: Int

        static let canonical = Configuration(
            sampleRate: 48_000,
            channelCount: 2,
            bitRate: 192_000
        )

        var pcmOutputSettings: [String: Any] {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
        }

        var aacOutputSettings: [String: Any] {
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: bitRate
            ]
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .canonical) {
        self.configuration = configuration
    }

    func export(inputURLs: [URL], outputURL: URL) async throws {
        let probes = await probeSources(inputURLs)

        do {
            let sources = try probes.map { try $0.requireReadableSource() }
            try sources.forEach(validateChannelLayout)
            let activeSources = sources.filter { $0.trackTimeRange.duration > .zero }

            guard !activeSources.isEmpty else {
                throw MixdownStageError(stage: "filter empty tracks", underlying: nil)
            }

            let composition = AVMutableComposition()
            let compositionTracks = try insert(activeSources, into: composition)
            let audioMix = makeAudioMix(for: compositionTracks)
            let readerResources = try makeReader(
                asset: composition,
                tracks: compositionTracks,
                audioMix: audioMix
            )
            let writerResources = try makeWriter(outputURL: outputURL)

            try await transferSamples(
                reader: readerResources.reader,
                output: readerResources.output,
                writer: writerResources.writer,
                input: writerResources.input
            )
        } catch {
            throw RecorderError.mixdownFailed(
                AudioMixdownDiagnostics.describe(error: error, probes: probes)
            )
        }
    }

    private func probeSources(_ urls: [URL]) async -> [SourceProbe] {
        await withTaskGroup(of: SourceProbe.self) { group in
            for url in urls {
                group.addTask {
                    await SourceProbe.load(url: url)
                }
            }

            var probes: [SourceProbe] = []
            for await probe in group {
                probes.append(probe)
            }
            return probes.sorted { $0.url.path < $1.url.path }
        }
    }

    private func validateChannelLayout(_ source: SourceAsset) throws {
        guard source.channelCount > 2 else {
            return
        }

        guard source.channelLayoutIsStandardMixable else {
            throw MixdownStageError(
                stage: "validate channel layout for \(source.url.lastPathComponent)",
                underlying: nil
            )
        }
    }

    private func insert(
        _ sources: [SourceAsset],
        into composition: AVMutableComposition
    ) throws -> [AVMutableCompositionTrack] {
        try sources.map { source in
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MixdownStageError(stage: "create composition audio track", underlying: nil)
            }

            try track.insertTimeRange(
                source.trackTimeRange,
                of: source.track,
                at: .zero
            )
            return track
        }
    }

    private func makeAudioMix(for tracks: [AVMutableCompositionTrack]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        return mix
    }

    private func makeReader(
        asset: AVAsset,
        tracks: [AVAssetTrack],
        audioMix: AVAudioMix
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: configuration.pcmOutputSettings
        )
        output.audioMix = audioMix

        guard reader.canAdd(output) else {
            throw MixdownStageError(stage: "add canonical audio mix output", underlying: nil)
        }

        reader.add(output)
        return (reader, output)
    }

    private func makeWriter(
        outputURL: URL
    ) throws -> (writer: AVAssetWriter, input: AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: configuration.aacOutputSettings
        )

        guard writer.canAdd(input) else {
            throw MixdownStageError(stage: "add canonical AAC writer input", underlying: nil)
        }

        writer.add(input)
        return (writer, input)
    }

    private func transferSamples(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) async throws {
        guard writer.startWriting() else {
            throw MixdownStageError(stage: "start writer", underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            writer.cancelWriting()
            throw MixdownStageError(stage: "start reader", underlying: reader.error)
        }

        try await SampleBufferTransfer.run(
            reader: reader,
            output: output,
            writer: writer,
            input: input
        )
    }
}

fileprivate struct SourceAsset {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let trackTimeRange: CMTimeRange
    let sampleRate: Double
    let channelCount: Int
    let formatID: AudioFormatID
    let isInterleaved: Bool
    let channelLayoutTag: AudioChannelLayoutTag?

    var channelLayoutIsStandardMixable: Bool {
        guard let channelLayoutTag else {
            return false
        }

        let nonStandardTags: Set<AudioChannelLayoutTag> = [
            kAudioChannelLayoutTag_UseChannelDescriptions,
            kAudioChannelLayoutTag_UseChannelBitmap,
            kAudioChannelLayoutTag_Unknown
        ]

        let layoutFamily = channelLayoutTag & 0xFFFF_0000
        let discreteFamily = kAudioChannelLayoutTag_DiscreteInOrder & 0xFFFF_0000

        guard !nonStandardTags.contains(channelLayoutTag),
              layoutFamily != discreteFamily else {
            return false
        }

        return Int(channelLayoutTag & 0x0000_FFFF) == channelCount
    }

    var diagnosticDescription: String {
        let format = Self.fourCharacterCode(formatID)
        let interleaving = isInterleaved ? "interleaved" : "non-interleaved"
        let layout = channelLayoutTag.map(String.init) ?? "missing"
        return "\(url.lastPathComponent): \(sampleRate) Hz, \(channelCount) ch, \(format), \(interleaving), layout=\(layout), duration=\(trackTimeRange.duration.seconds)s"
    }

    private static func fourCharacterCode(_ value: AudioFormatID) -> String {
        let scalars = [24, 16, 8, 0].map { shift -> UnicodeScalar in
            let byte = UInt8((value >> AudioFormatID(shift)) & 0xFF)
            return UnicodeScalar(byte >= 32 && byte <= 126 ? byte : 46)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

fileprivate enum SourceProbe {
    case readable(SourceAsset)
    case unreadable(URL, Error)

    var url: URL {
        switch self {
        case let .readable(source):
            source.url
        case let .unreadable(url, _):
            url
        }
    }

    static func load(url: URL) async -> SourceProbe {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)

            guard let track = tracks.first else {
                throw MixdownStageError(stage: "load audio track from \(url.lastPathComponent)", underlying: nil)
            }

            let timeRange = try await track.load(.timeRange)
            let descriptions = try await track.load(.formatDescriptions)

            guard let description = descriptions.first,
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                throw MixdownStageError(stage: "load audio format from \(url.lastPathComponent)", underlying: nil)
            }

            var layoutSize = 0
            let channelLayout = CMAudioFormatDescriptionGetChannelLayout(
                description,
                sizeOut: &layoutSize
            )
            let flags = streamDescription.pointee.mFormatFlags
            let source = SourceAsset(
                url: url,
                asset: asset,
                track: track,
                trackTimeRange: timeRange,
                sampleRate: streamDescription.pointee.mSampleRate,
                channelCount: Int(streamDescription.pointee.mChannelsPerFrame),
                formatID: streamDescription.pointee.mFormatID,
                isInterleaved: flags & kAudioFormatFlagIsNonInterleaved == 0,
                channelLayoutTag: channelLayout?.pointee.mChannelLayoutTag
            )
            return .readable(source)
        } catch {
            return .unreadable(url, error)
        }
    }

    func requireReadableSource() throws -> SourceAsset {
        switch self {
        case let .readable(source):
            source
        case let .unreadable(url, error):
            throw MixdownStageError(
                stage: "probe source \(url.lastPathComponent)",
                underlying: error
            )
        }
    }

    var diagnosticDescription: String {
        switch self {
        case let .readable(source):
            source.diagnosticDescription
        case let .unreadable(url, error):
            "\(url.lastPathComponent): unreadable (\(AudioMixdownDiagnostics.errorChain(error)))"
        }
    }
}

struct MixdownStageError: Error {
    let stage: String
    let underlying: Error?
}

enum AudioMixdownDiagnostics {
    fileprivate static func describe(error: Error, probes: [SourceProbe]) -> String {
        let sourceSummary = probes.map(\.diagnosticDescription).joined(separator: "; ")
        return "Mixdown failed. Sources: [\(sourceSummary)]. Error: \(errorChain(error))"
    }

    static func describe(error: Error, inputURLs: [URL]) async -> String {
        var probes: [SourceProbe] = []
        for url in inputURLs {
            probes.append(await SourceProbe.load(url: url))
        }
        return describe(error: error, probes: probes.sorted { $0.url.path < $1.url.path })
    }

    static func errorChain(_ error: Error) -> String {
        if let stageError = error as? MixdownStageError {
            let nsError = stageError as NSError
            let nested = stageError.underlying.map { "; \(errorChain($0))" } ?? ""
            return "stage=\(stageError.stage), domain=\(nsError.domain), code=\(nsError.code)\(nested)"
        }

        if let publicationError = error as? MixdownPublicationError {
            return publicationError.diagnosticDescription
        }

        let nsError = error as NSError
        var components = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            components.append("underlying={\(errorChain(underlying))}")
        }

        return components.joined(separator: ", ")
    }
}

private final class SampleBufferTransfer: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.dio0550.mac-meet-log.mixdown-transfer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false
    private var isFinishing = false

    private init(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    static func run(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) async throws {
        let transfer = SampleBufferTransfer(
            reader: reader,
            output: output,
            writer: writer,
            input: input
        )

        try await withTaskCancellationHandler {
            try await transfer.start()
        } onCancel: {
            transfer.cancel()
        }
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                self?.transferAvailableSamples()
            }
        }
    }

    private func transferAvailableSamples() {
        while input.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                finishReading()
                return
            }

            guard input.append(sampleBuffer) else {
                fail(stage: "append sample buffer", underlying: writer.error)
                return
            }
        }
    }

    private func finishReading() {
        guard beginFinishing() else {
            return
        }

        guard reader.status == .completed else {
            fail(stage: "read samples", underlying: reader.error)
            return
        }

        input.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else {
                fail(stage: "finish writer", underlying: writer.error)
                return
            }

            complete(with: .success(()))
        }
    }

    private func beginFinishing() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, !isFinishing else {
            return false
        }

        isFinishing = true
        return true
    }

    private func fail(stage: String, underlying: Error?) {
        reader.cancelReading()
        writer.cancelWriting()
        complete(with: .failure(MixdownStageError(stage: stage, underlying: underlying)))
    }

    private func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
        complete(with: .failure(CancellationError()))
    }

    private func complete(with result: Result<Void, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
