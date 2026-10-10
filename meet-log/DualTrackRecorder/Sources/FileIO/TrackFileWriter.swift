import AVFoundation
import Foundation

final class TrackFileWriter: TrackWriting {
    enum State: Equatable {
        case open
        case paused
        case closed
    }

    let url: URL

    private var state: State = .open
    private var audioFile: AVAudioFile?
    private var lastFormat: AVAudioFormat?
    private var recoverySegments: RecoveryAudioSegments
    private let audioFileFactory: (URL, AVAudioFormat) throws -> AVAudioFile
    private var converter: AVAudioConverter?
    private var conversionBuffer: AVAudioPCMBuffer?

    init(
        url: URL,
        audioFileFactory: @escaping (URL, AVAudioFormat) throws -> AVAudioFile = TrackFileWriter.makeAACFile
    ) {
        self.url = url
        self.audioFileFactory = audioFileFactory
        recoverySegments = RecoveryAudioSegments(trackURL: url)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        switch state {
        case .open:
            break
        case .paused:
            return
        case .closed:
            throw RecorderError.outputFailed("Cannot write to a closed writer.")
        }

        guard buffer.frameLength > 0 else {
            return
        }

        do {
            let file = try audioFile ?? makeAudioFile(for: buffer.format)
            try prepareConverter(for: buffer.format, file: file)

            guard let converter else {
                try writeOutput(buffer, to: file)
                return
            }

            try convert(buffer, using: converter, to: file)
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.outputFailed("Could not write audio track: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard state == .open else {
            return
        }

        // Keep the filter history and pending frames across pause/resume.
        // Paused input is discarded without ever reaching the converter.
        state = .paused
    }

    func resume() {
        guard state == .paused else {
            return
        }

        state = .open
    }

    func close() throws -> URL {
        guard state != .closed else {
            throw RecorderError.outputFailed("Cannot close an already closed writer.")
        }

        state = .closed
        var finalizationError: Error?

        do {
            if audioFile == nil {
                _ = try makeAudioFile(for: defaultFormat())
            }

            if let audioFile {
                try drainConverter(to: audioFile)
            }
        } catch {
            finalizationError = error
        }

        // Always release the AAC file and finalize recovery segments, even if
        // conversion failed. Preserve the first error for the caller.
        converter = nil
        conversionBuffer = nil
        audioFile = nil

        do {
            try recoverySegments.close()
        } catch {
            if finalizationError == nil {
                finalizationError = error
            }
        }

        if let error = finalizationError as? RecorderError {
            throw error
        }

        if let finalizationError {
            throw RecorderError.outputFailed("Could not finalize audio track: \(finalizationError.localizedDescription)")
        }

        return url
    }

    private func makeAudioFile(for format: AVAudioFormat) throws -> AVAudioFile {
        lastFormat = format

        do {
            let file = try audioFileFactory(url, format)
            audioFile = file
            return file
        } catch {
            throw RecorderError.outputFailed("Could not create audio file: \(error.localizedDescription)")
        }
    }

    private static func makeAACFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: 128_000
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    private func prepareConverter(for inputFormat: AVAudioFormat, file: AVAudioFile) throws {
        let outputFormat = file.processingFormat
        if let converter,
           converter.inputFormat.isEqual(inputFormat),
           converter.outputFormat.isEqual(outputFormat) {
            return
        }

        // End the old stream before either starting a new converter or writing
        // a buffer that already matches the file's PCM format.
        try drainConverter(to: file)

        guard !inputFormat.isEqual(outputFormat) else {
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.outputFailed("Could not convert audio buffer for writing.")
        }

        if conversionBuffer == nil {
            // Fixed capacity bounds retained memory independently of input size
            // and rate ratio. Full output is written in successive chunks.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                throw RecorderError.outputFailed("Could not allocate converted audio buffer.")
            }

            conversionBuffer = buffer
        }

        self.converter = converter
    }

    private func drainConverter(to file: AVAudioFile) throws {
        guard let converter else {
            return
        }

        try convert(nil, using: converter, to: file)
        self.converter = nil
    }

    private func convert(
        _ input: AVAudioPCMBuffer?,
        using converter: AVAudioConverter,
        to file: AVAudioFile
    ) throws {
        guard let output = conversionBuffer else {
            throw RecorderError.outputFailed("Missing converted audio buffer.")
        }

        // This flag spans all output chunks: each input is supplied exactly once.
        var didProvideInput = false
        let provideInput: AVAudioConverterInputBlock = { _, status in
            guard let input else {
                status.pointee = .endOfStream
                return nil
            }

            guard !didProvideInput else {
                status.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return input
        }

        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: provideInput)

            if let conversionError {
                throw RecorderError.outputFailed("Could not convert audio buffer: \(conversionError.localizedDescription)")
            }

            switch status {
            case .haveData:
                guard output.frameLength > 0 else {
                    throw RecorderError.outputFailed("Audio conversion made no progress.")
                }

                try writeOutput(output, to: file)
            case .inputRanDry:
                try writeOutput(output, to: file)
                guard input != nil else {
                    throw RecorderError.outputFailed("Audio conversion did not finish draining.")
                }

                return
            case .endOfStream:
                try writeOutput(output, to: file)
                guard input == nil else {
                    throw RecorderError.outputFailed("Audio conversion ended before the input stream closed.")
                }

                return
            case .error:
                throw RecorderError.outputFailed("Could not convert audio buffer.")
            @unknown default:
                throw RecorderError.outputFailed("Unknown audio conversion status.")
            }
        }
    }

    private func writeOutput(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        guard buffer.frameLength > 0 else {
            return
        }

        try file.write(from: buffer)
        try recoverySegments.write(buffer)
    }

    private func defaultFormat() -> AVAudioFormat {
        lastFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }
}
