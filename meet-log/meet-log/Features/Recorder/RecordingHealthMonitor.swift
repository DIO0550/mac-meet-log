import DualTrackRecorder
import Foundation

/// Pure policy driven by a monotonic clock. Level events arrive only with audio buffers.
struct RecordingHealthMonitor {
    enum Warning: Hashable {
        case silence(RecordingTrack)
        case noBuffers(RecordingTrack)
        case microphoneDisconnected
        case lowStorage
        case criticalStorage
        case storageUnavailable

        var message: String {
            switch self {
            case let .silence(track):
                "\(track == .microphone ? "Microphone" : "System audio"): no audible signal for 30 seconds. Recording continues."
            case let .noBuffers(track):
                "\(track == .microphone ? "Microphone" : "System audio"): no audio buffers for 5 seconds. Check the device and input selection. Recording continues."
            case .microphoneDisconnected:
                "The active microphone was disconnected or the default input changed. Check the input and select an available microphone."
            case .lowStorage:
                "Storage is running low. Free space or finish this recording soon."
            case .criticalStorage:
                "Storage is critically low. Recording is stopping to save source tracks; mixdown is skipped."
            case .storageUnavailable:
                "Free space could not be checked. Verify that the recording destination is still available."
            }
        }
    }

    enum StorageStatus: Equatable { case normal, low, critical, unavailable }
    static let criticalBytes: Int64 = 256 * 1_024 * 1_024
    static func storageStatus(bytes: Int64?, screenEnabled: Bool) -> StorageStatus {
        guard let bytes else { return .unavailable }
        if bytes <= criticalBytes { return .critical }
        let warningBytes: Int64 = (screenEnabled ? 2_048 : 512) * 1_024 * 1_024
        if bytes <= warningBytes { return .low }
        return .normal
    }

    private struct Signal {
        var lastBuffer: TimeInterval
        var lastAudible: TimeInterval
    }
    private var signals: [RecordingTrack: Signal] = [:]
    private var lastWarnings: [Warning: TimeInterval] = [:]

    mutating func begin(sources: RecordingSources, at time: TimeInterval) {
        lastWarnings = [:]
        resume(sources: sources, at: time)
    }

    mutating func resume(sources: RecordingSources, at time: TimeInterval) {
        signals = [:]
        if sources.systemAudioEnabled { reset(.systemAudio, at: time) }
        if sources.microphoneEnabled { reset(.microphone, at: time) }
    }

    mutating func pause() { signals = [:] }

    mutating func reset(_ track: RecordingTrack, at time: TimeInterval) {
        signals[track] = Signal(lastBuffer: time, lastAudible: time)
    }

    mutating func receive(_ snapshot: AudioLevelSnapshot, at time: TimeInterval) {
        guard var signal = signals[snapshot.track] else { return }
        // Resume silence timing after an outage; missing buffers are not evidence of silence.
        if time - signal.lastBuffer >= 5 { signal.lastAudible = time }
        signal.lastBuffer = time
        if snapshot.rms >= 0.001 { signal.lastAudible = time } // -60 dBFS
        signals[snapshot.track] = signal
    }

    mutating func audioWarnings(at time: TimeInterval) -> [Warning] {
        var warnings: [Warning] = []
        for track in [RecordingTrack.systemAudio, .microphone] {
            guard let signal = signals[track] else { continue }
            if time - signal.lastBuffer >= 5 {
                if shouldNotify(.noBuffers(track), at: time) { warnings.append(.noBuffers(track)) }
                continue
            }
            if time - signal.lastAudible >= 30, shouldNotify(.silence(track), at: time) {
                warnings.append(.silence(track))
            }
        }
        return warnings
    }

    mutating func shouldNotify(_ warning: Warning, at time: TimeInterval) -> Bool {
        if let last = lastWarnings[warning], time - last < 60 { return false }
        lastWarnings[warning] = time
        return true
    }
}

/// Pins the checked destination for the entire session, even if Settings changes.
@MainActor
final class RecordingDestination {
    private let resolve: () throws -> URL
    private var directory: URL?
    private var testDirectory: URL?

    init(resolve: @escaping () throws -> URL) { self.resolve = resolve }

    func prepare(isTest: Bool) throws -> Int64? {
        if let testDirectory {
            try FileManager.default.removeItem(at: testDirectory)
            self.testDirectory = nil
        }
        directory = nil
        let url = try isTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("meet-log-test-\(UUID().uuidString)")
            : resolve()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        if isTest { testDirectory = url }
        return try availableBytes()
    }

    func preparedURL() throws -> URL {
        guard let directory else { throw RecorderError.outputFailed("Check the destination before recording.") }
        return directory
    }

    func availableBytes() throws -> Int64? {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: preparedURL().path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }

    deinit {
        if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
    }
}
