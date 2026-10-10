import AVFoundation
import Foundation

// Admission is protected by admissionLock. Only processingQueue touches the writer,
// meter and writeFailed; owned PCM buffers are transferred to that queue once.
final class TrackProcessor: @unchecked Sendable {
    let track: RecordingTrack

    private let writer: any TrackWriting
    private let processingQueue: DispatchQueue
    private let admissionLock = NSLock()
    private let maximumPendingOperations: Int
    private let maximumPendingBytes: Int
    private var pendingOperations = 0
    private var pendingBytes = 0
    private var isPaused = false
    private var isClosing = false
    private var firstError: RecorderError?

    // These properties belong exclusively to processingQueue.
    private var meter = AudioLevelMeter()
    private var writeFailed = false
    private let eventHandler: @Sendable (RecorderEvent) -> Void

    init(
        track: RecordingTrack,
        writer: any TrackWriting,
        maximumPendingOperations: Int = 64,
        maximumPendingBytes: Int = 8 * 1_024 * 1_024,
        eventHandler: @escaping @Sendable (RecorderEvent) -> Void
    ) {
        precondition(maximumPendingOperations > 0 && maximumPendingBytes > 0)
        self.track = track
        self.writer = writer
        self.maximumPendingOperations = maximumPendingOperations
        self.maximumPendingBytes = maximumPendingBytes
        processingQueue = DispatchQueue(label: "DualTrackRecorder.\(track.rawValue).processing")
        self.eventHandler = eventHandler
    }

    var failure: RecorderError? {
        admissionLock.withLock { firstError }
    }

    func append(_ buffer: AVAudioPCMBuffer, time _: AVAudioTime?) {
        admissionLock.lock()
        defer { admissionLock.unlock() }

        guard !isPaused, !isClosing, firstError == nil, buffer.frameLength > 0 else {
            return
        }

        do {
            let byteCount = try OwnedPCMBuffer.byteCount(for: buffer)
            guard pendingOperations < maximumPendingOperations,
                  byteCount <= maximumPendingBytes - pendingBytes else {
                failAdmission(.outputFailed("Audio processing queue is full for \(track.rawValue). Recording is incomplete."))
                return
            }

            // Both microphone and bufferListNoCopy tap memory may be reused as
            // soon as this callback returns. Allocate only the active frames.
            let owned = try OwnedPCMBuffer(copying: buffer, byteCount: byteCount)
            pendingOperations += 1
            pendingBytes += byteCount
            processingQueue.async { self.process(owned) }
        } catch {
            failAdmission(normalize(error))
        }
    }

    func pause() {
        admissionLock.withLock {
            guard !isPaused, !isClosing, firstError == nil else {
                return
            }

            isPaused = true
            // The barrier follows all pre-pause buffers. Paused input never
            // consumes queue capacity, even while earlier writes are blocked.
            enqueueControl { self.writer.pause() }
        }
    }

    func resume() {
        admissionLock.withLock {
            guard isPaused, !isClosing, firstError == nil else {
                return
            }

            enqueueControl { self.writer.resume() }
            isPaused = false
        }
    }

    func close() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            admissionLock.withLock {
                guard !isClosing else {
                    continuation.resume(throwing: RecorderError.outputFailed("Cannot close an already closing audio processor."))
                    return
                }

                isClosing = true
                processingQueue.async {
                    continuation.resume(with: Result { try self.finish() })
                }
            }
        }
    }

    private func process(_ owned: OwnedPCMBuffer) {
        defer {
            admissionLock.withLock {
                pendingOperations -= 1
                pendingBytes -= owned.byteCount
            }
        }

        guard !writeFailed else {
            return
        }

        do {
            try writer.write(owned.buffer)
            meter.events(for: owned.buffer, track: track).forEach(eventHandler)
        } catch {
            writeFailed = true
            failProcessing(normalize(error))
        }
    }

    // Called with admissionLock held. Controls share the operation limit so
    // repeated pause/resume cannot build an unlimited backlog behind a slow disk.
    private func enqueueControl(_ action: @escaping @Sendable () -> Void) {
        guard pendingOperations < maximumPendingOperations else {
            failAdmission(.outputFailed("Audio processing control queue is full for \(track.rawValue). Recording is incomplete."))
            return
        }

        pendingOperations += 1
        processingQueue.async {
            action()
            self.admissionLock.withLock { self.pendingOperations -= 1 }
        }
    }

    private func finish() throws -> URL {
        // Finalize even after an admission/write failure so AAC headers and
        // recovery segments for successfully written audio are released.
        var resultURL = writer.url
        do {
            resultURL = try writer.close()
        } catch {
            failProcessing(normalize(error))
        }

        if let failure {
            throw failure
        }

        return resultURL
    }

    // Called with admissionLock held; never invoke application code on input.
    private func failAdmission(_ error: RecorderError) {
        guard firstError == nil else {
            return
        }

        firstError = error
        processingQueue.async { self.eventHandler(.stateChanged(.failed(error))) }
    }

    private func failProcessing(_ error: RecorderError) {
        let shouldPublish = admissionLock.withLock {
            guard firstError == nil else {
                return false
            }

            firstError = error
            return true
        }

        if shouldPublish {
            eventHandler(.stateChanged(.failed(error)))
        }
    }

    private func normalize(_ error: Error) -> RecorderError {
        if let recorderError = error as? RecorderError {
            return recorderError
        }

        return .outputFailed("Could not process \(track.rawValue): \(error.localizedDescription)")
    }
}
