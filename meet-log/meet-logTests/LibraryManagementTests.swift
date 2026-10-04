import DualTrackRecorder
import Foundation
import Testing
@testable import meet_log

@MainActor
struct LibraryManagementTests {
    @Test func namesAndTagsRoundTripWithoutRenamingMediaOrSidecars() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        try f.write("meeting_transcript.md", text: "saved OCR")
        let original = try await f.item()
        try f.service.saveMetadata(RecordingDisplayMetadata(name: "  週次会議  ", tags: ["開発", " 開発 ", "", "Team"], createdAt: original.createdAt), for: original)
        let restored = try await f.item()
        #expect(restored.title == "週次会議")
        #expect(restored.tags == ["Team", "開発"])
        #expect(restored.mixdownURL == original.mixdownURL)
        #expect(restored.id == original.id)
        #expect(try String(contentsOf: f.url("meeting_transcript.md"), encoding: .utf8) == "saved OCR")
        var matches: [LibrarySearchResult] = []
        for await progress in LibrarySearchService(summaryStore: MeetingSummarySidecarStore()).search(query: "開発", items: [restored]) {
            matches = progress.results
        }
        #expect(matches.first?.matches.first?.section == .tags)
        let model = LibraryViewModel(store: f.store)
        await model.load()
        model.selectedTag = "開発"
        #expect(model.filteredItems.count == 1)
        model.selectedTag = "別のタグ"
        #expect(model.filteredItems.isEmpty)
    }

    @Test func screenOnlyPreservesAudioTextAndOtherMeetings() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        for name in ["meeting_mix.m4a", "meeting_screen.mp4", "meeting_transcript.md", "meeting_summary.md", "meeting_notes.json", "meeting-other_screen.mp4"] {
            try f.write(name)
        }
        let plan = try f.service.plan(for: await f.item(), scope: .screen)
        #expect(plan.files.map(\.url.lastPathComponent) == ["meeting_screen.mp4"])
        #expect(plan.totalBytes == 7)
        let result = try f.service.execute(plan)
        #expect(result.failures.isEmpty)
        #expect(f.exists("meeting_mix.m4a"))
        #expect(f.exists("meeting_transcript.md"))
        #expect(f.exists("meeting_summary.md"))
        #expect(f.exists("meeting_notes.json"))
        #expect(f.exists("meeting-other_screen.mp4"))
        #expect(!f.exists("meeting_screen.mp4"))
        #expect(try await f.item().screenRemoved)
    }

    @Test func screenOnlyMeetingRemainsDiscoverableAfterVideoDeletion() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_screen.mp4")
        let item = try await f.item()
        _ = try f.service.execute(f.service.plan(for: item, scope: .screen))
        let restored = try await f.item()
        #expect(restored.id == item.id)
        #expect(restored.screenRemoved)
        #expect(restored.existingScreenCaptureURL == nil)
    }

    @Test func allUsesExactAllowlistAndRetainsUnrelatedFiles() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        for name in ["meeting_mix.m4a", "meeting_screen.mp4", "meeting_summary.md", "meeting_notes.json", "meeting-other_mix.m4a", "meeting_private.txt"] { try f.write(name) }
        let item = try await f.item()
        try f.service.saveMetadata(RecordingDisplayMetadata(name: "name", tags: [], createdAt: item.createdAt), for: item)
        let plan = try f.service.plan(for: item, scope: .all)
        #expect(plan.files.count == 5)
        let result = try f.service.execute(plan)
        #expect(result.moved.count == 5)
        #expect(result.failures.isEmpty)
        #expect(f.exists("meeting-other_mix.m4a"))
        #expect(f.exists("meeting_private.txt"))
        #expect(try await f.store.recordings().allSatisfy { $0.id != item.id })
    }

    @Test func partialPermissionFailurePreservesMetadataAndReportsFile() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        try f.write("meeting_screen.mp4")
        let item = try await f.item()
        try f.service.saveMetadata(RecordingDisplayMetadata(name: "retained", tags: [], createdAt: item.createdAt), for: item)
        var service = f.service
        service.trash = { url in
            if url.lastPathComponent == "meeting_mix.m4a" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: f.trash.appendingPathComponent(url.lastPathComponent))
        }
        let result = try service.execute(service.plan(for: item, scope: .all))
        #expect(result.moved.count == 1)
        #expect(result.failures.contains { $0.contains("meeting_mix.m4a") })
        #expect(f.exists("meeting_library.json"))
        #expect(try await f.item().title == "retained")
    }

    @Test func disappearingFileIsReportedAndRemainingFilesStillMove() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        try f.write("meeting_screen.mp4")
        let plan = try f.service.plan(for: await f.item(), scope: .all)
        try FileManager.default.removeItem(at: f.url("meeting_screen.mp4"))
        let result = try f.service.execute(plan)
        #expect(result.moved.count == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].contains("meeting_screen.mp4"))
    }

    @Test func changedPreviewAndSymlinksAreRejected() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        let item = try await f.item()
        let plan = try f.service.plan(for: item, scope: .all)
        try f.write("meeting_mix.m4a", text: "changed and larger")
        #expect(throws: LibraryManagementError.self) { try f.service.execute(plan) }
        try f.write("unrelated.mp4")
        try FileManager.default.createSymbolicLink(at: f.url("meeting_screen.mp4"), withDestinationURL: f.url("unrelated.mp4"))
        #expect(throws: LibraryManagementError.self) { try f.service.plan(for: item, scope: .screen) }
        #expect(f.exists("unrelated.mp4"))
    }

    @Test func metadataCannotOverwriteDirectoryOrSymlink() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        let item = try await f.item()
        try f.write("unrelated.json", text: "keep")
        try FileManager.default.createSymbolicLink(at: f.url("meeting_library.json"), withDestinationURL: f.url("unrelated.json"))
        #expect(throws: LibraryManagementError.self) {
            try f.service.saveMetadata(RecordingDisplayMetadata(name: "bad", tags: [], createdAt: .now), for: item)
        }
        #expect(try String(contentsOf: f.url("unrelated.json"), encoding: .utf8) == "keep")
    }

    @Test func recoveredMeetingIncludesOnlyMatchingOriginalMediaAndBackupSegments() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        let journal = RecordingJournal(startedAt: .now, stem: "meeting", sources: RecordingSources(systemAudioEnabled: true, microphoneEnabled: false))
        try journal.save(in: f.directory)
        let recovered = f.url("recovered")
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try JSONEncoder().encode(RecoveryReport(sessionID: journal.id, messages: [], noteCount: 0))
            .write(to: recovered.appendingPathComponent("recovery-report.json"))
        for name in ["meeting_mix.m4a", "meeting_screen.mp4"] {
            try f.write(name)
            try Data("restored".utf8).write(to: recovered.appendingPathComponent(name))
        }
        let segments = f.url("meeting_system.segments")
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let segment = segments.appendingPathComponent("00000000000000000000-00000000000005000000.m4a")
        try Data("backup".utf8).write(to: segment)
        try Data("keep".utf8).write(to: segments.appendingPathComponent("unrelated.txt"))
        let item = try await f.item()
        #expect(item.id == "recovered-\(journal.id.uuidString)")
        let videoPlan = try f.service.plan(for: item, scope: .screen)
        #expect(videoPlan.files.count == 2)
        let allPlan = try f.service.plan(for: item, scope: .all)
        #expect(allPlan.files.contains { $0.url.path == segment.path })
        #expect(allPlan.files.count == 5)
        // Keep actual moves in separate destinations when the original and recovery share a filename.
        let service = LibraryTrashService(trash: { url in
            try FileManager.default.moveItem(at: url, to: f.trash.appendingPathComponent(UUID().uuidString))
        })
        let result = try service.execute(allPlan)
        #expect(result.failures.isEmpty)
        #expect(result.moved.count == 5)
        #expect(FileManager.default.fileExists(atPath: segments.appendingPathComponent("unrelated.txt").path))
        #expect(try await f.store.recordings().isEmpty)
    }

    @Test func activeRecordingAndOtherWindowActivityPreventChanges() async throws {
        let f = try ManagementFixture()
        defer { f.remove() }
        try f.write("meeting_mix.m4a")
        let item = try await f.item()
        let plan = try f.service.plan(for: item, scope: .all)
        do {
            let lease = try RecordingSessionLease(directory: f.directory)
            defer { withExtendedLifetime(lease) {} }
            #expect(throws: RecordingSessionLease.LeaseError.self) { try f.service.execute(plan) }
        }
        let activity = LibraryActivity.begin(item.mixdownURL)
        defer { LibraryActivity.end(activity) }
        #expect(throws: LibraryManagementError.self) { try f.service.execute(plan) }
        #expect(throws: LibraryManagementError.self) {
            try f.service.saveMetadata(RecordingDisplayMetadata(name: "busy", tags: [], createdAt: .now), for: item)
        }
        #expect(f.exists("meeting_mix.m4a"))
    }
}

@MainActor
private struct ManagementFixture {
    let root: URL
    let directory: URL
    let trash: URL
    var store: OutputDirectoryRecordingLibraryStore {
        OutputDirectoryRecordingLibraryStore(outputDirectoryURL: directory, durationProvider: ManagementDuration())
    }
    var service: LibraryTrashService {
        LibraryTrashService(trash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("recordings")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func write(_ name: String, text: String = "content") throws { try Data(text.utf8).write(to: url(name)) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
    func item() async throws -> RecordingLibraryItem { try #require(await store.recordings().first { $0.storageStem == "meeting" }) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct ManagementDuration: RecordingDurationProviding {
    func duration(for url: URL) -> Duration? { nil }
}
