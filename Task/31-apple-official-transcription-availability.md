# Apple Official Transcription Availability

Issue: #3
Status: Completed
Last updated: 2026-05-24

## Purpose

Apple official frameworks can support an audio-file-to-transcript-to-summary pipeline, but the project needs explicit availability gates before implementation. This note records the API requirements, failure modes, and implementation boundaries for the follow-up issues.

## Target Pipeline

```text
audio file
  -> AVFoundation file loading
  -> Speech framework transcription
  -> Foundation Models summarization
  -> transcript / summary / topics / action items
```

The supply-chain goal remains unchanged: no third-party speech model, no external LLM, and no cloud transcription path for the Apple-native pipeline.

## API Matrix

| Capability | Preferred API | Fallback API | Minimum OS / SDK | Notes |
|---|---|---|---|---|
| Audio file loading | `AVAudioFile` | `AVAsset` when metadata-only access is enough | Existing app target | `AVAudioFile` should be the first validation point for mp3, m4a, wav, aac, caf, and aiff. |
| Speech transcription | `SpeechAnalyzer` + `SpeechTranscriber` | `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest` | macOS 26 SDK for new API; older macOS support for legacy API | New API must be isolated behind compile-time and runtime availability checks. |
| Speech model assets | `AssetInventory` | Not available for legacy API | macOS 26 SDK | Check supported locale, installed locale, and download progress before starting transcription. |
| Summary / extraction | `LanguageModelSession` | No Apple-only summary fallback | macOS 26 SDK and Apple Intelligence availability | Use only after `SystemLanguageModel.default.availability == .available`. |
| Structured summary | `@Generable` + `@Guide` | Plain text response | macOS 26 SDK | Use for topics, decisions, action items, and category once the framework is available. |

## Implementation Boundary

Do not import macOS 26-only frameworks from broad app files. Keep them in narrow adapters so the rest of the app can continue to build with the current project shape.

Recommended boundaries:

```swift
protocol AudioTranscriptionService {
    func transcribe(audioURL: URL, locale: Locale) async throws -> TranscriptResult
}

protocol TranscriptSummaryService {
    func summarize(transcript: String) async throws -> AudioSummary
}
```

Recommended adapters:

| Adapter | Responsibility | Availability |
|---|---|---|
| `LegacySpeechTranscriptionService` | `SFSpeechRecognizer` file transcription | Current app target, gated by authorization and recognizer support |
| `SpeechAnalyzerTranscriptionService` | `SpeechAnalyzer` + `SpeechTranscriber` file transcription | `#if canImport(Speech)` plus `@available(macOS 26.0, *)` |
| `FoundationModelsSummaryService` | `LanguageModelSession` summary and structured extraction | `#if canImport(FoundationModels)` plus `@available(macOS 26.0, *)` |
| `UnavailableSummaryService` | User-facing unsupported reason | Default fallback when Foundation Models is not available |

The concrete service selector should make one decision per run and expose the selected route to the UI for diagnostics.

## Runtime Checks

### Legacy Speech

Use the legacy path only when all checks pass:

- `SFSpeechRecognizer.requestAuthorization` returns `.authorized`.
- `SFSpeechRecognizer(locale:)` returns a recognizer.
- `recognizer.isAvailable == true`.
- `recognizer.supportsOnDeviceRecognition == true` when `requiresOnDeviceRecognition` is set.

If `supportsOnDeviceRecognition` is false, do not silently fall back to network recognition. Return an unsupported reason because the feature promise is on-device processing.

Required Info.plist key:

- `NSSpeechRecognitionUsageDescription`

### SpeechAnalyzer

Use the new Speech path only when all checks pass:

- Runtime OS is macOS 26 or later.
- `SpeechTranscriber.supportedLocales` contains the requested locale.
- `SpeechTranscriber.installedLocales` contains the locale, or `AssetInventory.assetInstallationRequest(supporting:)` can download and install the required asset.
- The app can observe asset download progress and cancellation.

Implementation notes:

- Prefer `.offlineTranscription` for existing files.
- Collect only `isFinal` results for the stored transcript.
- Use `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` when converting live buffers or custom decoded input.
- For file transcription, prefer `analyzeSequence(from:)` plus `finalizeAndFinish` when progress accounting is needed.

### Foundation Models

Use summarization only when:

- Runtime OS is macOS 26 or later.
- `SystemLanguageModel.default.availability == .available`.

Map unavailable reasons to user-facing states:

| Reason | UI / domain meaning |
|---|---|
| `.deviceNotEligible` | Device does not support Apple Intelligence. |
| `.appleIntelligenceNotEnabled` | Apple Intelligence is disabled in Settings. |
| `.modelNotReady` | Model assets are still preparing or downloading. |
| `@unknown default` | Unknown Foundation Models availability failure. |

For long transcripts, use chunked summarization followed by a final merge summary instead of sending the full transcript in one prompt.

## Feature Flag / Route Policy

Use explicit routes instead of booleans:

```swift
enum TranscriptionRoute: Equatable {
    case speechAnalyzer
    case legacySpeechRecognizer
    case unavailable(String)
}

enum SummaryRoute: Equatable {
    case foundationModels
    case unavailable(String)
}
```

Selection order:

1. Choose `speechAnalyzer` on macOS 26+ when the locale and asset checks pass.
2. Choose `legacySpeechRecognizer` when the new path is unavailable but on-device legacy recognition is supported.
3. Choose `unavailable` with the first actionable reason.
4. Choose `foundationModels` only when `SystemLanguageModel.default.availability` is available.
5. Otherwise keep the transcript and skip summary with an actionable unsupported reason.

## Project Decisions

- Keep the current deployment target unchanged for now. The app can add macOS 26-only features with availability-gated adapters rather than raising the entire app target immediately.
- Do not add Whisper, llama.cpp, model weights, or external APIs for this Apple-native path.
- Add `NSSpeechRecognitionUsageDescription` now because the legacy Speech path requires it.
- Keep `NSMicrophoneUsageDescription` for recording and live transcription; it is already present.
- Treat the new Speech model assets as Apple-managed system assets, not app-bundled resources.

## Follow-up Issue Guidance

- #4 should validate audio files with `AVAudioFile` and return typed import errors.
- #5 should implement `LegacySpeechTranscriptionService` first because it can be exercised before macOS 26-only code lands.
- #6 should add `SpeechAnalyzerTranscriptionService` in a narrow, availability-gated file.
- #7 should add `FoundationModelsSummaryService` in a narrow, availability-gated file and include chunked summary strategy.
- #8 should compose the selected transcription and summary routes into a cancellable job.
- #9 should surface route, progress, and unsupported reasons in UI without exposing framework names as primary user copy.
- #10 should test route selection with fakes instead of requiring Apple Speech or Foundation Models at test time.
- #11 should convert this implementation note into user-facing requirements and developer documentation.

## References

- Apple Developer Documentation: Speech framework
- Apple Developer Documentation: `SFSpeechRecognizer`
- Apple Developer Documentation: `SFSpeechRecognitionRequest.requiresOnDeviceRecognition`
- Apple Developer Documentation: `AssetInventory`
- Apple Developer Documentation: Foundation Models framework
- Apple Developer Documentation: `LanguageModelSession`
- Apple Developer Documentation: `SystemLanguageModel.availability`
- GitHub issue comment: https://github.com/DIO0550/mac-meet-log/issues/2#issuecomment-4527835321
