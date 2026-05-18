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
            try file.write(from: buffer)
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
            let file = try AVAudioFile(forWriting: url, settings: settings)
            audioFile = file
            return file
        } catch {
            throw RecorderError.outputFailed("Could not create audio file: \(error.localizedDescription)")
        }
    }

    private func defaultFormat() -> AVAudioFormat {
        lastFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }
}
