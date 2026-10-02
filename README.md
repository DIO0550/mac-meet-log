# mac-meet-log

mac-meet-log records meetings on macOS and can process existing audio files with Apple-native transcription and summary APIs.

## Audio File Transcription And Summary

The audio processing flow accepts `mp3`, `m4a`, and `wav` files. A selected file is validated locally, transcribed with Apple's Speech framework, and then summarized with Apple's Foundation Models framework when the current Mac supports it.

The Apple-native path does not use external transcription APIs, external LLM APIs, Whisper, llama.cpp, or bundled third-party model weights. Transcript text is kept as the primary output, so a summary failure or unavailable Apple Intelligence state does not discard the transcript.

### Runtime Requirements

- macOS with Speech framework support for the selected locale.
- Speech recognition permission must be granted.
- Screen recording permission is required only when the Screen source is enabled.
- On-device speech recognition must be available for the selected locale.
- Foundation Models summary requires a compatible macOS SDK/runtime and Apple Intelligence availability.
- Apple Intelligence must be enabled and its model assets must be ready before summary generation can run.

When a Mac cannot summarize with Foundation Models, the app keeps the transcript visible and reports the unsupported reason. When transcription itself is unavailable, the processing view shows a typed error and offers retry or file selection again.

### Known Limits

- Supported import formats are intentionally limited to `mp3`, `m4a`, and `wav`.
- Foundation Models uses bounded inputs for long transcripts; a single unbroken word beyond the input limit is reported instead of truncated.
- The newer SpeechAnalyzer path is availability-gated and only used where Apple's runtime supports it.
- The app does not fall back to network transcription when on-device speech recognition is unavailable.

## Development Notes

- [Apple official transcription availability](Task/31-apple-official-transcription-availability.md)

### Timestamped notes

While recording or paused, enter a note and choose **Add** (or press Return).
The timestamp uses active recording time, excluding pauses. Notes appear in
chronological order in the recording result and Library details, where they can
be added, edited, or deleted. For saved recordings, enter the position in seconds.

Notes are saved atomically as `<recording>_notes.json` beside the audio tracks
when recording completes, including when mixdown fails. A missing sidecar means
there are no notes; an unreadable sidecar is reported and preserved. If saving
fails, keep the app open and use **Retry Saving Notes** before leaving the session.

### Screen capture

The recorder can optionally save a display, window, or application as a separate
`<recording>_screen.mp4` file beside the audio tracks. Screen capture uses Apple's
ScreenCaptureKit and requires macOS Screen Recording permission. If permission is
missing, the target disappears, or capture fails, system audio and microphone
recording continue and the app explains how to enable access.

The default is H.264 at 15 fps, up to 1920×1080, with a 4 Mbps target bit rate.
That is about 1.8 GB per hour before container overhead (roughly 7.2 GB for four
hours). There is no live preview: omitting it avoids a second video rendering path
during long meetings. Pause/resume drops paused frames and rewrites presentation
timestamps so the screen file stays on the same active-time timeline as audio and
timestamped notes.

### Speaker-labeled transcripts

Saved recordings with both source tracks are transcribed track by track. System
audio is labeled **相手** and microphone audio is labeled **自分**; segments are
merged by start time, including overlapping speech, and the labels are supplied
to summary generation for action-item ownership. If either source track is
missing or silent, the recording falls back to the existing single-audio
transcription path. Imported audio files also keep the single-audio path.

### Long meeting summaries

Foundation Models summaries above 24,000 characters are split at sentence or
utterance (newline) boundaries, with word boundaries used for longer sentences.
Chunks do not overlap. Every chunk is summarized, then the intermediate summaries
are integrated in bounded groups until one meeting summary remains. Integration
merges repeated topics/tasks; an additional deterministic pass removes duplicates
while preserving distinct owners/deadlines and topic details.

Both the import screen and Library display completed chunks and integration
progress. Any chunk or integration failure fails the whole summary with its
position/reason; partial summaries are never saved as complete. The transcript
remains available. Oversized words or intermediate outputs, and outputs that
cannot be reduced within the input limit, produce an explicit retryable error.
Short transcripts keep the existing single-call path. The existing extractive
fallback remains available without Apple Intelligence and accepts long text
without a model prompt limit.

### 設定（⌘,）

- macOS標準の設定画面で保存先、既定の録音ソース・マイク、文字起こし言語を変更できます。未設定時は従来の保存先、両ソース有効、日本語（ja-JP）を使います。
- 保存先はsecurity-scoped bookmarkとして保持します。変更は次の録音から適用し、既存ファイルは移動しません。ライブラリは現在の保存先のみを表示します。以前の録音を見る場合は元の保存先を選び直してください。
- 録音・再生・サイドカーファイルの保存を妨げないよう、使用した保存先のアクセスはアプリ終了まで維持します。保存先が利用できない場合は設定で選び直してください。
- 既定のマイクはデバイスUIDで保持し、未接続の場合はシステムの既定に戻ります。録音中の設定変更は録音終了後に反映します。
- 言語変更は次に開始する文字起こしから適用します。要約タブには標準会議テンプレートを表示します。テンプレートの追加・編集は #26 で拡張します。

### Screen text (OCR)

When generating a summary for a recording with a screen video, meet-log runs
Vision OCR **after audio transcription**, off the UI thread. No external OCR
service or model is used. Audio-only recordings skip this step entirely. OCR
failure is displayed as a warning and does not discard the audio transcript.

The fixed initial policy samples one frame every **2 seconds** (also the minimum
OCR interval). It compares a 320×180 grayscale thumbnail against the last frame
sent to OCR; recognition runs when at least **0.2%** of pixels change by **20/255**
or more. Comparing to the last recognized frame catches accumulating changes.
This sampling policy can miss brief slides or very small edits; it is not a
frame-exact archive. The original screen video remains available. OCR uses the
transcription locale, with English for technical terms/URLs; unsupported Vision
languages report a warning rather than silently switching languages.

Screen text is saved as separate timestamped `screenSegments` in the transcript
sidecar. Consecutive identical text is collapsed, while a blank screen ends the
previous segment. The library, search and export include this layer, and summary
prompts mark it as auxiliary screen information, never as spoken decisions.
Long inputs chunk audio and screen content separately to preserve provenance.

Each result stores sampled frames, OCR calls and wall-clock processing seconds,
shown below the screen text. `ScreenOCRIntegrationTests` generates a 60-second,
960×540 two-slide video, exercises AVFoundation + Vision, and prints a
`SCREEN_OCR_BENCHMARK` measurement in macOS CI. This synthetic measurement is not
an on-device long-meeting benchmark; actual cost depends on how often the screen
changes. Frames are processed one at a time, so image memory does not grow with
recording length. No OCR controls are exposed in Settings in this first version.
