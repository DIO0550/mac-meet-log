import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import meet_log

struct AudioImportTests {
    @Test func errorDescriptionsAreUserFacing() {
        let errors: [AudioImportError] = [
            .unsupportedFormat("txt"),
            .fileNotFound,
            .emptyFile,
            .permissionDenied("Denied"),
            .unreadable("Invalid data"),
            .metadataUnavailable("Missing duration")
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func importerRejectsUnsupportedExtensionsBeforeReading() async {
        let importer = AVAudioFileImporter()

        await #expect(throws: AudioImportError.unsupportedFormat("aac")) {
            try await importer.importAudio(from: URL(fileURLWithPath: "/tmp/audio.aac"))
        }

        await #expect(throws: AudioImportError.unsupportedFormat("txt")) {
            try await importer.importAudio(from: URL(fileURLWithPath: "/tmp/audio.txt"))
        }

        await #expect(throws: AudioImportError.unsupportedFormat("")) {
            try await importer.importAudio(from: URL(fileURLWithPath: "/tmp/audio"))
        }
    }

    @Test func allowedContentTypesStaySpecificAndUnique() {
        let types = AudioImportAllowedContentTypes.values

        #expect(types.count == Set(types).count)
        #expect(!types.contains(.audio))
        #expect(types.contains { $0.preferredFilenameExtension == "mp3" })
        #expect(types.contains { $0.preferredFilenameExtension == "m4a" })
        #expect(types.contains { $0.preferredFilenameExtension == "wav" })
    }

    @Test func importerAcceptsSupportedExtensionsCaseInsensitively() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let importer = AVAudioFileImporter()

        for fileName in ["audio.mp3", "audio.MP3", "audio.m4a", "audio.wav"] {
            await #expect(throws: AudioImportError.fileNotFound) {
                try await importer.importAudio(from: directoryURL.appendingPathComponent(fileName))
            }
        }
    }

    @Test func importerClassifiesMissingAndEmptyFiles() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let missingURL = directoryURL.appendingPathComponent("missing.wav")
        let emptyURL = directoryURL.appendingPathComponent("empty.wav")
        try Data().write(to: emptyURL)

        let importer = AVAudioFileImporter()

        await #expect(throws: AudioImportError.fileNotFound) {
            try await importer.importAudio(from: missingURL)
        }

        await #expect(throws: AudioImportError.emptyFile) {
            try await importer.importAudio(from: emptyURL)
        }
    }

    @Test func importerClassifiesUnavailableFileSizeAsUnreadable() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let unknownSizeURL = directoryURL.appendingPathComponent("unknown-size.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownSizeURL, withIntermediateDirectories: true)

        let importer = AVAudioFileImporter()

        await #expect(throws: AudioImportError.unreadable("File size is unavailable.")) {
            try await importer.importAudio(from: unknownSizeURL)
        }
    }

    @Test func importerReadsGeneratedWavMetadata() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let audioURL = directoryURL.appendingPathComponent("fixture.WAV")
        try writeSilentWav(to: audioURL)

        let item = try await AVAudioFileImporter().importAudio(from: audioURL)

        #expect(item.url == audioURL)
        #expect(item.fileName == "fixture.WAV")
        #expect(item.fileExtension == "wav")
        #expect(item.byteSize > 0)
        #expect(item.duration > .zero)
        #expect(item.channelCount == 1)
        #expect(item.sampleRate == 44_100)
    }

    @MainActor
    @Test func viewModelPresentsImporter() {
        let viewModel = AudioImportViewModel(importer: FakeAudioFileImporter(result: .success(makeImportedItem())))

        viewModel.presentImporter()

        #expect(viewModel.isImporterPresented)
    }

    @MainActor
    @Test func viewModelPublishesImportedItem() async throws {
        let item = makeImportedItem()
        let viewModel = AudioImportViewModel(importer: FakeAudioFileImporter(result: .success(item)))

        viewModel.handleImporterResult(.success(item.url))
        try await waitForImportToFinish(viewModel)

        #expect(viewModel.state == .imported(item))
    }

    @MainActor
    @Test func viewModelPublishesTypedImportError() async throws {
        let error = AudioImportError.unsupportedFormat("txt")
        let viewModel = AudioImportViewModel(importer: FakeAudioFileImporter(result: .failure(error)))

        viewModel.handleImporterResult(.success(URL(fileURLWithPath: "/tmp/audio.txt")))
        try await waitForImportToFinish(viewModel)

        #expect(viewModel.state == .failed(error))
    }

    @MainActor
    @Test func viewModelMapsUnknownErrorToUnreadable() async throws {
        let viewModel = AudioImportViewModel(importer: FakeAudioFileImporter(result: .failure(TestImportError.boom)))

        viewModel.handleImporterResult(.success(URL(fileURLWithPath: "/tmp/audio.wav")))
        try await waitForImportToFinish(viewModel)

        guard case let .failed(error) = viewModel.state else {
            Issue.record("Expected failed state.")
            return
        }

        guard case .unreadable = error else {
            Issue.record("Expected unreadable error, got \(error).")
            return
        }
    }

    @MainActor
    @Test func viewModelTreatsPickerCancelAsIdle() {
        let viewModel = AudioImportViewModel(importer: FakeAudioFileImporter(result: .failure(TestImportError.boom)))
        viewModel.presentImporter()

        viewModel.handleImporterResult(.failure(CocoaError(.userCancelled)))

        #expect(viewModel.state == .idle)
        #expect(!viewModel.isImporterPresented)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSilentWav(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(4_410)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    @MainActor
    private func waitForImportToFinish(_ viewModel: AudioImportViewModel) async throws {
        for _ in 0..<50 where viewModel.state == .importing {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct FakeAudioFileImporter: AudioFileImporting, @unchecked Sendable {
    let result: Result<AudioImportItem, Error>

    func importAudio(from url: URL) async throws -> AudioImportItem {
        try result.get()
    }
}

private enum TestImportError: Error {
    case boom
}

private func makeImportedItem() -> AudioImportItem {
    AudioImportItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        url: URL(fileURLWithPath: "/tmp/imported.wav"),
        fileName: "imported.wav",
        fileExtension: "wav",
        byteSize: 1_024,
        duration: .seconds(2),
        channelCount: 1,
        sampleRate: 44_100
    )
}
