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

    init(url: URL) {
        self.url = url
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

        do {
            let file = try audioFile ?? makeAudioFile(for: buffer.format)
            let writableBuffer = try bufferForWriting(buffer, to: file.processingFormat)
            try file.write(from: writableBuffer)
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

        if audioFile == nil {
            do {
                _ = try makeAudioFile(for: defaultFormat())
            } catch let error as RecorderError {
                throw error
            } catch {
                throw RecorderError.outputFailed("Could not finalize empty audio track: \(error.localizedDescription)")
            }
        }

        audioFile = nil
        return url
    }

    private func makeAudioFile(for format: AVAudioFormat) throws -> AVAudioFile {
        lastFormat = format

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: 128_000
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            audioFile = file
            return file
        } catch {
            throw RecorderError.outputFailed("Could not create audio file: \(error.localizedDescription)")
        }
    }

    private func bufferForWriting(
        _ buffer: AVAudioPCMBuffer,
        to processingFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard !buffer.format.isCompatible(with: processingFormat) else {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: processingFormat) else {
            throw RecorderError.outputFailed("Could not convert audio buffer for writing.")
        }

        let sampleRateRatio = processingFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up)) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: max(frameCapacity, 1)
        ) else {
            throw RecorderError.outputFailed("Could not allocate converted audio buffer.")
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw RecorderError.outputFailed("Could not convert audio buffer: \(conversionError.localizedDescription)")
        }

        return convertedBuffer
    }

    private func defaultFormat() -> AVAudioFormat {
        lastFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }
}

private extension AVAudioFormat {
    func isCompatible(with other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat
            && sampleRate == other.sampleRate
            && channelCount == other.channelCount
            && isInterleaved == other.isInterleaved
    }
}
