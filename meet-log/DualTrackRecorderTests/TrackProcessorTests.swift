import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import DualTrackRecorder

struct TrackProcessorTests {
    @Test func blockedWriterDoesNotBlockInputOrControlsAndCloseDrainsInOrder() async throws {
        let writer = GatedTrackWriter()
        defer { writer.release.signal() }
        let events = ProcessorEvents()
        let processor = TrackProcessor(track: .microphone, writer: writer, eventHandler: events.append)
        let first = try makeBuffer(value: 0.1)
        let second = try makeBuffer(value: 0.2)
        let paused = try makeBuffer(value: 0.3)
        let resumed = try makeBuffer(value: 0.4)
        let returned = DispatchSemaphore(value: 0)

        // A synchronous writer would leave this callback blocked at write().
        DispatchQueue.global().async {
            processor.append(first, time: nil)
            returned.signal()
        }
        #expect(await waitForSignal(returned) == .success)
        #expect(await waitForSignal(writer.started) == .success)
        #expect(events.snapshot.isEmpty)

        DispatchQueue.global().async {
            processor.append(second, time: AVAudioTime(hostTime: 2))
            processor.pause()
            processor.append(paused, time: AVAudioTime(hostTime: 3))
            processor.resume()
            processor.append(resumed, time: AVAudioTime(hostTime: 4))
            returned.signal()
        }
        #expect(await waitForSignal(returned) == .success)
        #expect(writer.operations.isEmpty)

        let closing = Task { try await processor.close() }
        writer.release.signal()
        #expect(try await closing.value == writer.url)
        #expect(writer.operations == [
            .write(sampleData(first)), .write(sampleData(second)),
            .pause, .resume, .write(sampleData(resumed)), .close
        ])
        #expect(events.snapshot.contains { event in
            if case .level = event {
                return true
            }
            return false
        })
        #expect(processor.failure == nil)

        processor.append(first, time: nil)
        processor.pause()
        processor.resume()
        await #expect(throws: RecorderError.self) { try await processor.close() }
        #expect(writer.operations.count == 6)
    }

    @Test(arguments: [false, true])
    func borrowedStereoSamplesAreCopiedBeforeReturning(interleaved: Bool) async throws {
        let writer = GatedTrackWriter()
        defer { writer.release.signal() }
        let processor = TrackProcessor(track: .systemAudio, writer: writer, eventHandler: { _ in })
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: interleaved
        ))
        // Spare capacity must not be retained/copied into the processing queue.
        let original = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        original.frameLength = 4
        fillBytes(original, with: 0x12)
        let borrowed = try #require(AVAudioPCMBuffer(
            pcmFormat: format, bufferListNoCopy: original.audioBufferList, deallocator: nil
        ))
        borrowed.frameLength = original.frameLength
        let expected = sampleData(borrowed)
        let returned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            processor.append(borrowed, time: nil)
            returned.signal()
        }
        #expect(await waitForSignal(returned) == .success)
        #expect(await waitForSignal(writer.started) == .success)
        fillBytes(original, with: 0x67)
        writer.release.signal()
        _ = try await processor.close()

        #expect(writer.operations == [.write(expected), .close])
        #expect(writer.capacities == [4])
        #expect(expected.reduce(0) { $0 + $1.count } == 16)
    }

    @Test(arguments: [false, true])
    func countAndByteLimitsIncludeTheInFlightBuffer(useByteLimit: Bool) async throws {
        let writer = GatedTrackWriter()
        defer { writer.release.signal() }
        let events = ProcessorEvents()
        let maximumBuffers = useByteLimit ? 64 : 2
        let maximumBytes = useByteLimit ? 16 : 1_024
        let processor = TrackProcessor(
            track: .microphone, writer: writer,
            maximumPendingOperations: maximumBuffers, maximumPendingBytes: maximumBytes,
            eventHandler: events.append
        )
        let buffer = try makeBuffer(value: 0.1) // 4 frames × Float = 16 bytes
        processor.append(buffer, time: nil)
        #expect(await waitForSignal(writer.started) == .success)
        if !useByteLimit {
            processor.append(buffer, time: nil)
        }
        processor.append(buffer, time: nil)
        let failure = try #require(processor.failure)
        #expect(failure.localizedDescription.contains("queue is full"))

        for _ in 0..<1_000 {
            processor.append(buffer, time: nil)
        }
        writer.release.signal()
        await #expect(throws: failure) { try await processor.close() }

        let expectedWrites = useByteLimit ? 1 : 2
        let writes = writer.operations.filter { operation in
            if case .write = operation {
                return true
            }
            return false
        }
        #expect(writes.count == expectedWrites)
        #expect(writer.operations.last == .close)
        #expect(events.failures == [failure])
    }

    @Test func oversizedBufferFailsWithoutWritingAndEmptyInputUsesNoCapacity() async throws {
        let writer = GatedTrackWriter(blockFirstWrite: false)
        let events = ProcessorEvents()
        let processor = TrackProcessor(
            track: .systemAudio, writer: writer, maximumPendingBytes: 8, eventHandler: events.append
        )
        let buffer = try makeBuffer(value: 0.1)
        buffer.frameLength = 0
        processor.append(buffer, time: nil)
        #expect(processor.failure == nil)
        buffer.frameLength = 4
        processor.append(buffer, time: nil)
        let failure = try #require(processor.failure)
        await #expect(throws: failure) { try await processor.close() }
        #expect(writer.operations == [.close])
        #expect(events.failures == [failure])
    }

    @Test func pauseResumeBacklogIsAlsoBounded() async throws {
        let writer = GatedTrackWriter()
        defer { writer.release.signal() }
        let events = ProcessorEvents()
        let processor = TrackProcessor(
            track: .microphone, writer: writer, maximumPendingOperations: 3, eventHandler: events.append
        )
        let buffer = try makeBuffer(value: 0.1)
        processor.append(buffer, time: nil)
        #expect(await waitForSignal(writer.started) == .success)
        processor.pause()
        processor.resume()
        processor.pause()
        let failure = try #require(processor.failure)
        for _ in 0..<1_000 {
            processor.resume()
            processor.pause()
        }
        writer.release.signal()
        await #expect(throws: failure) { try await processor.close() }
        #expect(writer.operations == [.write(sampleData(buffer)), .pause, .resume, .close])
        #expect(events.failures == [failure])
    }

    @Test func writeFailureDiscardsPendingAudioButFinalizesAndReportsOnce() async throws {
        let error = RecorderError.outputFailed("injected disk failure")
        let writer = GatedTrackWriter(writeError: error, closeError: .outputFailed("later close failure"))
        defer { writer.release.signal() }
        let events = ProcessorEvents()
        let processor = TrackProcessor(track: .microphone, writer: writer, eventHandler: events.append)
        let buffer = try makeBuffer(value: 0.1)
        processor.append(buffer, time: nil)
        #expect(await waitForSignal(writer.started) == .success)
        processor.append(buffer, time: nil)
        writer.release.signal()

        await #expect(throws: error) { try await processor.close() }
        processor.append(buffer, time: nil)
        #expect(writer.operations == [.write(sampleData(buffer)), .close])
        #expect(events.snapshot == [.stateChanged(.failed(error))])
        #expect(processor.failure == error)
    }

    @Test func concurrentCallbacksHaveOneWriterOwner() async throws {
        let writer = GatedTrackWriter(blockFirstWrite: false)
        let processor = TrackProcessor(
            track: .microphone, writer: writer, maximumPendingOperations: 200, eventHandler: { _ in }
        )
        let buffer = try makeBuffer(value: 0.1)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            processor.append(buffer, time: nil)
        }
        _ = try await processor.close()
        #expect(writer.operations.count == 101)
        #expect(writer.operations.last == .close)
        #expect(processor.failure == nil)
        #expect(!writer.hadConcurrentAccess)
    }

    @Test func recorderStopWaitsForQueuedWritesBeforeMixdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = FakeRecorderHarness(baseURL: root)
        let writer = GatedTrackWriter()
        defer { writer.release.signal() }
        let capture = EmittingAudioCapture()
        var dependencies = harness.dependencies
        dependencies.writerFactory = { _, _ in writer }
        dependencies.systemAudioCaptureFactory = { handler in
            capture.handler = handler
            return capture
        }
        let recorder = DualTrackRecorder(dependencies: dependencies)
        try await recorder.start(sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false))
        let buffer = try makeBuffer(value: 0.1)
        capture.handler?(buffer, nil)
        #expect(await waitForSignal(writer.started) == .success)
        capture.handler?(buffer, nil)
        let stopping = Task { try await recorder.stop() }
        #expect(await waitForSignal(capture.stopped) == .success)
        #expect(writer.operations.isEmpty)
        #expect(harness.mixdownExporter.requestedSystemAudioURL == nil)
        writer.release.signal()
        let result = try await stopping.value
        #expect(writer.operations == [.write(sampleData(buffer)), .write(sampleData(buffer)), .close])
        #expect(result.systemAudioURL == writer.url)
        #expect(harness.mixdownExporter.requestedSystemAudioURL == writer.url)
    }

    @Test func recorderWriteFailureStopsCaptureAndFinalizesBeforePublishingFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = FakeRecorderHarness(baseURL: root)
        let error = RecorderError.outputFailed("injected capture-time disk failure")
        let writer = GatedTrackWriter(blockFirstWrite: false, writeError: error)
        let capture = EmittingAudioCapture()
        var dependencies = harness.dependencies
        dependencies.writerFactory = { track, _ in
            if track == .systemAudio {
                return writer
            }
            return GatedTrackWriter(blockFirstWrite: false)
        }
        dependencies.systemAudioCaptureFactory = { handler in
            capture.handler = handler
            return capture
        }
        let recorder = DualTrackRecorder(dependencies: dependencies)
        let failed = DispatchSemaphore(value: 0)
        let reader = Task {
            for await event in recorder.events {
                if case let .stateChanged(.failed(reportedError)) = event {
                    #expect(reportedError == error)
                    failed.signal()
                    return
                }
            }
        }
        defer { reader.cancel() }
        try await recorder.start(sources: RecordingSources())
        let buffer = try makeBuffer(value: 0.1)
        capture.handler?(buffer, nil)
        try #require(await waitForSignal(failed) == .success)
        #expect(await waitForSignal(capture.stopped) == .success)
        #expect(writer.operations == [.write(sampleData(buffer)), .close])
        #expect(harness.microphoneCapture.stopCount == 1)
        #expect(harness.mixdownExporter.requestedDestinationURL == nil)
        // The recorder's own session state, as well as the UI event, is failed.
        try await recorder.dismiss()
    }

    private func makeBuffer(value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let data = try #require(buffer.floatChannelData?[0])
        for frame in 0..<4 {
            data[frame] = value
        }
        return buffer
    }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 2))
        }
    }
}

private func sampleData(_ buffer: AVAudioPCMBuffer) -> [Data] {
    UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).map {
        Data(bytes: $0.mData!, count: Int($0.mDataByteSize))
    }
}

private func fillBytes(_ buffer: AVAudioPCMBuffer, with byte: Int32) {
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        memset(channel.mData!, byte, Int(channel.mDataByteSize))
    }
}

private final class ProcessorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RecorderEvent] = []

    func append(_ event: RecorderEvent) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [RecorderEvent] { lock.withLock { events } }

    var failures: [RecorderError] {
        snapshot.compactMap {
            guard case let .stateChanged(.failed(error)) = $0 else {
                return nil
            }
            return error
        }
    }
}

private final class GatedTrackWriter: TrackWriting, @unchecked Sendable {
    enum Operation: Equatable {
        case write([Data])
        case pause
        case resume
        case close
    }

    let url = URL(fileURLWithPath: "/tmp/track-processor-test.m4a")
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockFirstWrite: Bool
    private let writeError: RecorderError?
    private let closeError: RecorderError?
    private var recordedOperations: [Operation] = []
    private var recordedCapacities: [AVAudioFrameCount] = []
    private var activeCalls = 0
    private var concurrentAccess = false
    private var hasStarted = false
    private var paused = false

    init(blockFirstWrite: Bool = true, writeError: RecorderError? = nil, closeError: RecorderError? = nil) {
        self.blockFirstWrite = blockFirstWrite
        self.writeError = writeError
        self.closeError = closeError
    }

    var operations: [Operation] { lock.withLock { recordedOperations } }
    var capacities: [AVAudioFrameCount] { lock.withLock { recordedCapacities } }
    var hadConcurrentAccess: Bool { lock.withLock { concurrentAccess } }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        enter()
        defer { leave() }
        let isFirst = lock.withLock {
            let isFirst = !hasStarted
            hasStarted = true
            return isFirst
        }
        if isFirst, blockFirstWrite {
            started.signal()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw RecorderError.outputFailed("Test writer gate timed out.")
            }
        }
        lock.withLock {
            // Match TrackFileWriter: input while paused is discarded.
            if !paused {
                recordedOperations.append(.write(sampleData(buffer)))
                recordedCapacities.append(buffer.frameCapacity)
            }
        }
        if let writeError {
            throw writeError
        }
    }

    func pause() {
        enter()
        defer { leave() }
        lock.withLock {
            paused = true
            recordedOperations.append(.pause)
        }
    }

    func resume() {
        enter()
        defer { leave() }
        lock.withLock {
            paused = false
            recordedOperations.append(.resume)
        }
    }

    func close() throws -> URL {
        enter()
        defer { leave() }
        lock.withLock { recordedOperations.append(.close) }
        if let closeError {
            throw closeError
        }
        return url
    }

    private func enter() {
        lock.withLock {
            activeCalls += 1
            if activeCalls > 1 {
                concurrentAccess = true
            }
        }
    }

    private func leave() {
        lock.withLock { activeCalls -= 1 }
    }
}

private final class EmittingAudioCapture: AudioCapture {
    var handler: AudioBufferHandler?
    let stopped = DispatchSemaphore(value: 0)

    func start() async throws {}
    func stop() {
        stopped.signal()
    }
}
