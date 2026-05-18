import AVFoundation
import Foundation

typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void

protocol AudioCapture: AnyObject {
    func start() async throws
    func stop()
}

protocol TrackWriting: AnyObject {
    var url: URL { get }

    func write(_ buffer: AVAudioPCMBuffer) throws
    func pause()
    func resume()
    func close() throws -> URL
}

protocol MixdownExporting {
    func export(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        destinationURL: URL
    ) async throws -> URL
}
