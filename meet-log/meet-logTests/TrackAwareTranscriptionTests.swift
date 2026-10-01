import Foundation
import Testing
@testable import meet_log

struct TrackAwareTranscriptionTests {
    private let systemURL = URL(fileURLWithPath: "/tmp/meeting_system.m4a")
    private let microphoneURL = URL(fileURLWithPath: "/tmp/meeting_microphone.m4a")
    private let mixURL = URL(fileURLWithPath: "/tmp/meeting_mix.m4a")

    @Test func mergesTracksByStartTimeAndPreservesOverlappingSpeech() async throws {
        let service = TrackAwareTranscriptionService(
            service: URLTranscriptionService(results: [
                systemURL: .success(
                    transcript(
                        text: "相手の発言",
                        url: systemURL,
                        segments: [
                            TranscriptSegment(text: "最初", timestamp: 1, duration: 2),
                            TranscriptSegment(text: "重なった相手", timestamp: 4, duration: 3)
                        ]
                    )
                ),
                microphoneURL: .success(
                    transcript(
                        text: "自分の発言",
                        url: microphoneURL,
                        segments: [
                            TranscriptSegment(text: "重なった自分", timestamp: 4, duration: 1),
                            TranscriptSegment(text: "最後", timestamp: 8, duration: 1)
                        ]
                    )
                )
            ])
        )

        let result = try await service.finalTranscript(
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result.sourceURL == mixURL)
        #expect(result.segments.map(\.text) == ["最初", "重なった相手", "重なった自分", "最後"])
        #expect(result.segments.map(\.speaker) == [.other, .other, .me, .me])
        #expect(result.text == "相手: 最初\n相手: 重なった相手\n自分: 重なった自分\n自分: 最後")
    }

    @Test func fallsBackToSuccessfulSingleTrackWhenOtherTrackIsEmpty() async throws {
        let microphoneTranscript = transcript(text: "自分だけ", url: microphoneURL)
        let service = TrackAwareTranscriptionService(
            service: URLTranscriptionService(results: [
                systemURL: .failure(TranscriptionError.emptyResult),
                microphoneURL: .success(microphoneTranscript)
            ])
        )

        let result = try await service.finalTranscript(
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result == microphoneTranscript)
        #expect(result.segments.allSatisfy { $0.speaker == nil })
    }

    @Test func missingSourceTrackUsesSingleAudioFallback() async throws {
        let mixTranscript = transcript(text: "単一音声", url: mixURL)
        let fake = URLTranscriptionService(results: [mixURL: .success(mixTranscript)])
        let service = TrackAwareTranscriptionService(service: fake)

        let result = try await service.finalTranscript(
            systemAudioURL: nil,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result == mixTranscript)
        #expect(fake.requestedURLs == [mixURL])
    }

    @Test func bothTrackFailuresUseMixdownFallback() async throws {
        let mixTranscript = transcript(text: "mix", url: mixURL)
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(TranscriptionError.emptyResult),
            microphoneURL: .failure(TranscriptionError.emptyResult),
            mixURL: .success(mixTranscript)
        ])
        let service = TrackAwareTranscriptionService(service: fake)

        let result = try await service.finalTranscript(
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result == mixTranscript)
        #expect(fake.requestedURLs == [systemURL, microphoneURL, mixURL])
    }

    @Test func speakerLabelsAreIncludedInSummaryPrompt() throws {
        let transcript = TranscriptResult(
            text: "相手: 確認します\n自分: 対応します",
            localeIdentifier: "ja-JP",
            sourceURL: mixURL,
            segments: [
                TranscriptSegment(text: "確認します", timestamp: 0, duration: 1, speaker: .other),
                TranscriptSegment(text: "対応します", timestamp: 1, duration: 1, speaker: .me)
            ]
        )

        let prompt = try #require(SummaryPromptBuilder(characterLimit: 100).makePrompt(for: transcript).success)

        #expect(prompt.instructions.contains("話者ラベル"))
        #expect(prompt.instructions.contains("担当者推定"))
        #expect(prompt.prompt.contains("相手: 確認します"))
        #expect(prompt.prompt.contains("自分: 対応します"))
    }

    private func transcript(
        text: String,
        url: URL,
        segments: [TranscriptSegment] = []
    ) -> TranscriptResult {
        TranscriptResult(text: text, localeIdentifier: "ja-JP", sourceURL: url, segments: segments)
    }
}

private extension Result {
    var success: Success? {
        guard case let .success(value) = self else {
            return nil
        }

        return value
    }
}

private final class URLTranscriptionService: AudioTranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [URL: Result<TranscriptResult, Error>]
    private var requestedURLValues: [URL] = []

    init(results: [URL: Result<TranscriptResult, Error>]) {
        self.results = results
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requestedURLValues
    }

    func transcribe(audioURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        lock.lock()
        requestedURLValues.append(audioURL)
        let result = results[audioURL] ?? .failure(TranscriptionError.transcriptionIncomplete)
        lock.unlock()

        return AsyncThrowingStream { continuation in
            switch result {
            case let .success(transcript):
                continuation.yield(.completed(transcript))
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }
}
