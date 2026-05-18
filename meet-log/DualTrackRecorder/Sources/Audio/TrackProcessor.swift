import AVFoundation
import Foundation

final class TrackProcessor {
    let track: RecordingTrack
    let writer: any TrackWriting

    private var meter = AudioLevelMeter()
    private let eventHandler: @Sendable (RecorderEvent) -> Void
    private var firstError: RecorderError?

    init(
        track: RecordingTrack,
        writer: any TrackWriting,
        eventHandler: @escaping @Sendable (RecorderEvent) -> Void
    ) {
        self.track = track
        self.writer = writer
        self.eventHandler = eventHandler
    }

    var failure: RecorderError? {
        firstError
    }

    func append(_ buffer: AVAudioPCMBuffer, time _: AVAudioTime?) {
        guard firstError == nil else {
            return
        }

        do {
            try writer.write(buffer)
            meter.events(for: buffer, track: track).forEach(eventHandler)
        } catch let error as RecorderError {
            firstError = error
            eventHandler(.stateChanged(.failed(error)))
        } catch {
            let recorderError = RecorderError.outputFailed("Could not write \(track.rawValue): \(error.localizedDescription)")
            firstError = recorderError
            eventHandler(.stateChanged(.failed(recorderError)))
        }
    }

    func pause() {
        writer.pause()
    }

    func resume() {
        writer.resume()
    }

    func close() throws -> URL {
        if let firstError {
            throw firstError
        }

        return try writer.close()
    }
}
