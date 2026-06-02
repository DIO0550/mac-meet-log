import Foundation

enum TranscriptionServiceFactory {
    nonisolated static func makeDefault() -> AudioTranscriptionService {
        #if canImport(AVFoundation) && canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return FallbackAudioTranscriptionService(
                primary: SpeechAnalyzerTranscriptionService(),
                fallback: LegacySpeechTranscriptionService()
            )
        }
        #endif

        return LegacySpeechTranscriptionService()
    }
}
