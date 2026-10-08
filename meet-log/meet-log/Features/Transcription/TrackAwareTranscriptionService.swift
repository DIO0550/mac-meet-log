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
        try Task.checkCancellation()
        // Imported/mix-only audio has no source-track expectations.
        if systemAudioURL == nil, microphoneURL == nil {
            guard let fallbackURL else {
                throw TranscriptionError.transcriptionIncomplete
            }

            return try await service.finalTranscript(
                audioURL: fallbackURL,
                locale: locale
            )
        }

        let otherResult = try await trackResult(audioURL: systemAudioURL, locale: locale)
        let meResult = try await trackResult(audioURL: microphoneURL, locale: locale)
        try Task.checkCancellation()
        let issues = [
            otherResult.issue(speaker: .other), meResult.issue(speaker: .me)
        ].compactMap { $0 }
        let hasTranscript = otherResult.transcript != nil || meResult.transcript != nil
        let hasMissingSpeech = issues.contains { $0.reason != .noSpeech }
        var mixdownFailure: String?

        // No-speech on one side is expected; processing errors/missing material
        // require a mix retry even when the other side produced useful text.
        if let fallbackURL, hasMissingSpeech || !hasTranscript,
           fallbackURL != systemAudioURL, fallbackURL != microphoneURL {
            do {
                let transcript = try await service.finalTranscript(audioURL: fallbackURL, locale: locale)
                try Task.checkCancellation()
                return transcript.recording(report: TranscriptionReport(
                    coverage: .mixdown, trackIssues: issues, mixdownFailure: nil
                ))
            } catch {
                try TranscriptionCancellation.check(error)
                guard hasTranscript else {
                    throw error
                }
                mixdownFailure = error.localizedDescription
            }
        }

        guard hasTranscript else {
            throw otherResult.error ?? meResult.error ?? TranscriptionError.emptyResult
        }

        let report: TranscriptionReport?
        if issues.isEmpty {
            report = nil
        } else {
            report = TranscriptionReport(
                coverage: hasMissingSpeech ? .partial : .complete,
                trackIssues: issues, mixdownFailure: mixdownFailure
            )
        }
        guard let available = otherResult.transcript ?? meResult.transcript else {
            throw TranscriptionError.transcriptionIncomplete
        }
        let sourceURL = available.sourceURL
        return Self.merge(
            other: otherResult.transcript, me: meResult.transcript,
            sourceURL: hasMissingSpeech ? sourceURL : (fallbackURL ?? sourceURL),
            localeIdentifier: available.localeIdentifier
        ).recording(report: report)
    }

    private nonisolated func trackResult(
        audioURL: URL?,
        locale: Locale
    ) async throws -> TrackResult {
        try Task.checkCancellation()
        guard let audioURL else {
            return .missingSource
        }

        do {
            let transcript = try await service.finalTranscript(audioURL: audioURL, locale: locale)
            try Task.checkCancellation()
            guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .noSpeech
            }
            return .success(transcript)
        } catch {
            try TranscriptionCancellation.check(error)
            if error as? TranscriptionError == .emptyResult {
                return .noSpeech
            }
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                return .missingSource
            }
            return .failure(error)
        }
    }

    private nonisolated static func merge(
        other: TranscriptResult?,
        me: TranscriptResult?,
        sourceURL: URL,
        localeIdentifier: String
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
            localeIdentifier: localeIdentifier,
            sourceURL: sourceURL,
            segments: segments
        )
    }

    private nonisolated static func labeledSegments(
        from transcript: TranscriptResult?,
        speaker: TranscriptSpeaker
    ) -> [TranscriptSegment] {
        guard let transcript else {
            return []
        }
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

private nonisolated enum TrackResult {
    case success(TranscriptResult)
    case noSpeech
    case missingSource
    case failure(Error)

    var transcript: TranscriptResult? {
        guard case .success(let transcript) = self else {
            return nil
        }
        return transcript
    }

    var error: Error? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error
    }

    func issue(speaker: TranscriptSpeaker) -> TranscriptionReport.TrackIssue? {
        switch self {
        case .success:
            return nil
        case .noSpeech:
            return .init(speaker: speaker, reason: .noSpeech, message: nil)
        case .missingSource:
            return .init(speaker: speaker, reason: .missingSource, message: nil)
        case .failure(let error):
            return .init(speaker: speaker, reason: .processingFailed, message: error.localizedDescription)
        }
    }
}
