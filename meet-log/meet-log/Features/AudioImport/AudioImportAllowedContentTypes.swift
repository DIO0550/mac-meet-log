import UniformTypeIdentifiers

enum AudioImportAllowedContentTypes {
    static let values: [UTType] = uniqueTypes(for: ["mp3", "m4a", "wav"])

    private static func uniqueTypes(for filenameExtensions: [String]) -> [UTType] {
        var seen = Set<UTType>()
        return filenameExtensions.compactMap { filenameExtension in
            guard let type = UTType(filenameExtension: filenameExtension),
                  seen.insert(type).inserted else {
                return nil
            }

            return type
        }
    }
}
