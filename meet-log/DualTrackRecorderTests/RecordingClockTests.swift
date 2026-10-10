import Foundation
import Testing
@testable import DualTrackRecorder

struct RecordingClockTests {
    @Test(arguments: [false, true])
    func finalizationFreezesActiveDurationBeforeSlowWritersDrain(stopWhilePaused: Bool) async throws {
        let timeProvider = ManualTimeProvider(now: Date(timeIntervalSince1970: 0))
        let session = RecordingSession(clock: RecordingClock(timeProvider: timeProvider))
        _ = try await session.start(sources: RecordingSources())
        timeProvider.now = Date(timeIntervalSince1970: 10)
        _ = try await session.pause()
        timeProvider.now = Date(timeIntervalSince1970: 20)
        _ = try await session.resume()
        timeProvider.now = Date(timeIntervalSince1970: 25)
        if stopWhilePaused {
            _ = try await session.pause()
            timeProvider.now = Date(timeIntervalSince1970: 30)
        }
        #expect(try await session.startFinalizing() == .finalizing)
        timeProvider.now = Date(timeIntervalSince1970: 120)
        #expect(await session.elapsed == .seconds(15))
    }

    @Test func elapsedAdvancesWhileRecording() {
        let timeProvider = ManualTimeProvider(now: Date(timeIntervalSince1970: 0))
        var clock = RecordingClock(timeProvider: timeProvider)

        clock.start()
        timeProvider.now = Date(timeIntervalSince1970: 10)

        #expect(clock.elapsed == .seconds(10))
    }

    @Test func elapsedFreezesWhilePaused() throws {
        let timeProvider = ManualTimeProvider(now: Date(timeIntervalSince1970: 0))
        var clock = RecordingClock(timeProvider: timeProvider)

        clock.start()
        timeProvider.now = Date(timeIntervalSince1970: 10)
        _ = try clock.pause()
        timeProvider.now = Date(timeIntervalSince1970: 25)

        #expect(clock.elapsed == .seconds(10))
    }

    @Test func elapsedExcludesMultiplePausedPeriods() throws {
        let timeProvider = ManualTimeProvider(now: Date(timeIntervalSince1970: 0))
        var clock = RecordingClock(timeProvider: timeProvider)

        clock.start()
        timeProvider.now = Date(timeIntervalSince1970: 10)
        _ = try clock.pause()
        timeProvider.now = Date(timeIntervalSince1970: 15)
        try clock.resume()
        timeProvider.now = Date(timeIntervalSince1970: 22)
        _ = try clock.pause()
        timeProvider.now = Date(timeIntervalSince1970: 32)
        try clock.resume()

        #expect(clock.elapsed == .seconds(17))
    }
}

private final class ManualTimeProvider: TimeProviding, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
