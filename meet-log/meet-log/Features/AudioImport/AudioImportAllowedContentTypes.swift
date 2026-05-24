import UniformTypeIdentifiers

enum AudioImportAllowedContentTypes {
    static let values: [UTType] = [
        type(for: "mp3"),
        type(for: "m4a"),
        type(for: "wav")
    ]

    private static func type(for filenameExtension: String) -> UTType {
        UTType(filenameExtension: filenameExtension) ?? .audio
    }
}
