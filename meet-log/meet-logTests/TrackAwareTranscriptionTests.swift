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

    @Test func noSpeechRetainsSuccessfulTrackLabelWithoutMixRetry() async throws {
        let microphoneTranscript = transcript(text: "自分だけ", url: microphoneURL)
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(TranscriptionError.emptyResult),
            microphoneURL: .success(microphoneTranscript)
        ])
        let service = TrackAwareTranscriptionService(service: fake)

        let result = try await service.finalTranscript(
            systemAudioURL: systemURL,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result.text == "自分: 自分だけ")
        #expect(result.segments.map(\.speaker) == [.me])
        #expect(result.transcriptionReport?.coverage == .complete)
        #expect(result.transcriptionReport?.trackIssues.first?.reason == .noSpeech)
        #expect(fake.requestedURLs == [systemURL, microphoneURL])
    }

    @Test func missingSourceTrackUsesSingleAudioFallback() async throws {
        let mixTranscript = transcript(text: "単一音声", url: mixURL)
        let fake = URLTranscriptionService(results: [
            microphoneURL: .success(transcript(text: "自分", url: microphoneURL)),
            mixURL: .success(mixTranscript)
        ])
        let service = TrackAwareTranscriptionService(service: fake)

        let result = try await service.finalTranscript(
            systemAudioURL: nil,
            microphoneURL: microphoneURL,
            fallbackURL: mixURL
        )

        #expect(result.text == mixTranscript.text)
        #expect(result.transcriptionReport?.coverage == .mixdown)
        #expect(result.transcriptionReport?.trackIssues.first?.reason == .missingSource)
        #expect(fake.requestedURLs == [microphoneURL, mixURL])
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

        #expect(result.text == mixTranscript.text)
        #expect(result.transcriptionReport?.coverage == .mixdown)
        #expect(result.transcriptionReport?.trackIssues.map(\.reason) == [.noSpeech, .noSpeech])
        #expect(fake.requestedURLs == [systemURL, microphoneURL, mixURL])
    }

    @Test(arguments: [true, false])
    func oneRecognitionFailureRetriesMixdownAndReportsLostSpeakers(failingSystem: Bool) async throws {
        let failedURL = failingSystem ? systemURL : microphoneURL
        let goodURL = failingSystem ? microphoneURL : systemURL
        let failedSpeaker: TranscriptSpeaker = failingSystem ? .other : .me
        let fake = URLTranscriptionService(results: [
            failedURL: .failure(TranscriptionError.recognitionFailed("track failed")),
            goodURL: .success(transcript(text: "残った発言", url: goodURL)),
            mixURL: .success(transcript(text: "会議全体", url: mixURL))
        ])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
        )

        #expect(result.text == "会議全体")
        #expect(result.transcriptionReport?.coverage == .mixdown)
        #expect(result.transcriptionReport?.trackIssues.first?.speaker == failedSpeaker)
        #expect(result.transcriptionReport?.trackIssues.first?.reason == .processingFailed)
        #expect(result.transcriptionReport?.warningText.contains("話者区別はありません") == true)
        #expect(fake.requestedURLs == [systemURL, microphoneURL, mixURL])
    }

    @Test(arguments: [true, false])
    func recognitionFailureWithoutMixdownReturnsExplicitLabeledPartial(failingSystem: Bool) async throws {
        let failedURL = failingSystem ? systemURL : microphoneURL
        let goodURL = failingSystem ? microphoneURL : systemURL
        let goodSpeaker: TranscriptSpeaker = failingSystem ? .me : .other
        let fake = URLTranscriptionService(results: [
            failedURL: .failure(TranscriptionError.recognitionFailed("lost words")),
            goodURL: .success(transcript(text: "残った発言", url: goodURL))
        ])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: nil
        )

        #expect(result.transcriptionReport?.coverage == .partial)
        #expect(result.transcriptionReport?.trackIssues.first?.message?.contains("lost words") == true)
        #expect(result.segments.map(\.speaker) == [goodSpeaker])
        #expect(result.sourceURL == goodURL)
    }

    @Test func arbitraryReadFailureAndFailedMixKeepBothCausesInPartialResult() async throws {
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(NSError(domain: "read", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read"])),
            microphoneURL: .success(transcript(text: "残った発言", url: microphoneURL)),
            mixURL: .failure(TranscriptionError.recognitionFailed("mix failed"))
        ])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
        )

        #expect(result.transcriptionReport?.coverage == .partial)
        #expect(result.transcriptionReport?.trackIssues.first?.message == "cannot read")
        #expect(result.transcriptionReport?.mixdownFailure?.contains("mix failed") == true)
        #expect(result.segments.map(\.speaker) == [.me])
    }

    @Test func missingMaterialWithoutMixIsDifferentFromNoSpeech() async throws {
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)),
            microphoneURL: .success(transcript(text: "残った発言", url: microphoneURL))
        ])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: nil
        )
        #expect(result.transcriptionReport?.coverage == .partial)
        #expect(result.transcriptionReport?.trackIssues.first?.reason == .missingSource)
    }

    @Test func emptySuccessfulResultIsTreatedAsNoSpeech() async throws {
        let fake = URLTranscriptionService(results: [
            systemURL: .success(transcript(text: "  ", url: systemURL)),
            microphoneURL: .success(transcript(text: "発言", url: microphoneURL))
        ])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
        )
        #expect(result.transcriptionReport?.coverage == .complete)
        #expect(result.transcriptionReport?.trackIssues.first?.reason == .noSpeech)
        #expect(fake.requestedURLs == [systemURL, microphoneURL])
    }

    @Test func bothFailuresWithoutMixPropagateFailure() async {
        let error = TranscriptionError.recognitionFailed("system failed")
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(error), microphoneURL: .failure(TranscriptionError.emptyResult)
        ])
        await #expect(throws: error) {
            try await TrackAwareTranscriptionService(service: fake).finalTranscript(
                systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: nil
            )
        }
    }

    @Test(arguments: [0, 1, 2])
    func cancellationAtEitherTrackOrMixNeverReturnsSuccess(stage: Int) async {
        var results: [URL: Result<TranscriptResult, Error>] = [
            systemURL: .success(transcript(text: "相手", url: systemURL)),
            microphoneURL: .success(transcript(text: "自分", url: microphoneURL)),
            mixURL: .success(transcript(text: "mix", url: mixURL))
        ]
        let urls = [systemURL, microphoneURL, mixURL]
        results[urls[stage]] = .failure(CancellationError())
        if stage == 2 {
            results[systemURL] = .failure(TranscriptionError.recognitionFailed("failed"))
        }
        let fake = URLTranscriptionService(results: results)
        await #expect(throws: CancellationError.self) {
            try await TrackAwareTranscriptionService(service: fake).finalTranscript(
                systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
            )
        }
        #expect(fake.requestedURLs == Array(urls.prefix(stage + 1)))
    }

    @Test func platformCancellationIsAlsoPropagated() async {
        let fake = URLTranscriptionService(results: [
            systemURL: .failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)),
            microphoneURL: .success(transcript(text: "自分", url: microphoneURL))
        ])
        await #expect(throws: CancellationError.self) {
            try await TrackAwareTranscriptionService(service: fake).finalTranscript(
                systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
            )
        }
        #expect(fake.requestedURLs == [systemURL])
    }

    @Test func cancelledTaskCannotTurnCompletedStreamIntoFallbackSuccess() async {
        let fake = URLTranscriptionService(results: [
            systemURL: .success(transcript(text: "相手", url: systemURL)),
            microphoneURL: .success(transcript(text: "自分", url: microphoneURL)),
            mixURL: .success(transcript(text: "mix", url: mixURL))
        ], cancelAtURL: systemURL)
        let task = Task {
            try await TrackAwareTranscriptionService(service: fake).finalTranscript(
                systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: mixURL
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fake.requestedURLs == [systemURL])
    }

    @Test func importedMixOnlyAudioKeepsSingleFilePath() async throws {
        let input = transcript(text: "import", url: mixURL)
        let fake = URLTranscriptionService(results: [mixURL: .success(input)])
        let result = try await TrackAwareTranscriptionService(service: fake).finalTranscript(
            systemAudioURL: nil, microphoneURL: nil, fallbackURL: mixURL
        )
        #expect(result == input)
        #expect(fake.requestedURLs == [mixURL])
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

    private let cancelAtURL: URL?

    init(results: [URL: Result<TranscriptResult, Error>], cancelAtURL: URL? = nil) {
        self.results = results
        self.cancelAtURL = cancelAtURL
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
        if audioURL == cancelAtURL {
            withUnsafeCurrentTask { $0?.cancel() }
        }

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
