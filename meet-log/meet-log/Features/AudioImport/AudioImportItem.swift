import Foundation

struct AudioImportItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileExtension: String
    let byteSize: Int64
    let duration: Duration
    let channelCount: Int
    let sampleRate: Double

    nonisolated init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileExtension: String,
        byteSize: Int64,
        duration: Duration,
        channelCount: Int,
        sampleRate: Double
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.byteSize = byteSize
        self.duration = duration
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    var durationText: String {
        duration.mediaDurationDisplayString
    }

    var byteSizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}
