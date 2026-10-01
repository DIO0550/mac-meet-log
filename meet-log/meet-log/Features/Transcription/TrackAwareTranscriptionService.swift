import Foundation

struct TrackAwareTranscriptionService: Sendable {
    private let service: AudioTranscriptionService

    nonisolated init(service: AudioTranscriptionService) {
        self.service = service
    }

    nonisolated func finalTranscript(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        fallbackURL: URL?,
        locale: Locale = Locale(identifier: "ja-JP")
    ) async throws -> TranscriptResult {
        guard let systemAudioURL, let microphoneURL else {
            guard let singleAudioURL = fallbackURL ?? systemAudioURL ?? microphoneURL else {
                throw TranscriptionError.transcriptionIncomplete
            }

            return try await service.finalTranscript(
                audioURL: singleAudioURL,
                locale: locale
            )
        }

        let otherResult = await transcriptResult(audioURL: systemAudioURL, locale: locale)
        let meResult = await transcriptResult(audioURL: microphoneURL, locale: locale)

        switch (otherResult, meResult) {
        case (.success(let other), .success(let me)):
            return Self.merge(
                other: other,
                me: me,
                sourceURL: fallbackURL ?? systemAudioURL
            )
        case (.success(let transcript), .failure),
             (.failure, .success(let transcript)):
            return transcript
        case (.failure(let firstError), .failure):
            guard let fallbackURL else {
                throw firstError
            }

            return try await service.finalTranscript(audioURL: fallbackURL, locale: locale)
        }
    }

    private nonisolated func transcriptResult(
        audioURL: URL,
        locale: Locale
    ) async -> Result<TranscriptResult, Error> {
        do {
            return .success(try await service.finalTranscript(audioURL: audioURL, locale: locale))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func merge(
        other: TranscriptResult,
        me: TranscriptResult,
        sourceURL: URL
    ) -> TranscriptResult {
        let segments = (
            labeledSegments(from: other, speaker: .other)
                + labeledSegments(from: me, speaker: .me)
        ).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return speakerOrder(lhs.speaker) < speakerOrder(rhs.speaker)
            }

            return lhs.timestamp < rhs.timestamp
        }
        let text = segments
            .map { segment in
                guard let speaker = segment.speaker else {
                    return segment.text
                }

                return "\(speaker.displayName): \(segment.text)"
            }
            .joined(separator: "\n")

        return TranscriptResult(
            text: text,
            localeIdentifier: other.localeIdentifier,
            sourceURL: sourceURL,
            segments: segments
        )
    }

    private nonisolated static func labeledSegments(
        from transcript: TranscriptResult,
        speaker: TranscriptSpeaker
    ) -> [TranscriptSegment] {
        guard !transcript.segments.isEmpty else {
            return [
                TranscriptSegment(
                    text: transcript.text,
                    timestamp: 0,
                    duration: 0,
                    speaker: speaker
                )
            ]
        }

        return transcript.segments.map { segment in
            TranscriptSegment(
                text: segment.text,
                timestamp: segment.timestamp,
                duration: segment.duration,
                speaker: speaker
            )
        }
    }

    private nonisolated static func speakerOrder(_ speaker: TranscriptSpeaker?) -> Int {
        switch speaker {
        case .other:
            return 0
        case .me:
            return 1
        case nil:
            return 2
        }
    }
}
