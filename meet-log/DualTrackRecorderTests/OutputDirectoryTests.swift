import Foundation
import Testing
@testable import DualTrackRecorder

struct OutputDirectoryTests {
    @Test func createsMeetLogDirectoryAndNamesFilesByTimestamp() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputDirectoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputDirectory = OutputDirectory(url: rootURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(
            year: 2024,
            month: 1,
            day: 1,
            hour: 12,
            minute: 0,
            second: 5
        ))!

        let fileSet = try outputDirectory.fileSet(for: date)

        #expect(FileManager.default.fileExists(atPath: rootURL.path))
        #expect(fileSet.mixdownURL.lastPathComponent == "2024-01-01_12-00-05_mix.m4a")
        #expect(fileSet.systemAudioURL.lastPathComponent == "2024-01-01_12-00-05_system.m4a")
        #expect(fileSet.microphoneURL.lastPathComponent == "2024-01-01_12-00-05_microphone.m4a")
    }
}
