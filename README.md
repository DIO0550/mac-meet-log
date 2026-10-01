# mac-meet-log

mac-meet-log records meetings on macOS and can process existing audio files with Apple-native transcription and summary APIs.

## Audio File Transcription And Summary

The audio processing flow accepts `mp3`, `m4a`, and `wav` files. A selected file is validated locally, transcribed with Apple's Speech framework, and then summarized with Apple's Foundation Models framework when the current Mac supports it.

The Apple-native path does not use external transcription APIs, external LLM APIs, Whisper, llama.cpp, or bundled third-party model weights. Transcript text is kept as the primary output, so a summary failure or unavailable Apple Intelligence state does not discard the transcript.

### Runtime Requirements

- macOS with Speech framework support for the selected locale.
- Speech recognition permission must be granted.
- On-device speech recognition must be available for the selected locale.
- Foundation Models summary requires a compatible macOS SDK/runtime and Apple Intelligence availability.
- Apple Intelligence must be enabled and its model assets must be ready before summary generation can run.

When a Mac cannot summarize with Foundation Models, the app keeps the transcript visible and reports the unsupported reason. When transcription itself is unavailable, the processing view shows a typed error and offers retry or file selection again.

### Known Limits

- Supported import formats are intentionally limited to `mp3`, `m4a`, and `wav`.
- Long transcripts may exceed the current summary prompt limit.
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

### Speaker-labeled transcripts

Saved recordings with both source tracks are transcribed track by track. System
audio is labeled **相手** and microphone audio is labeled **自分**; segments are
merged by start time, including overlapping speech, and the labels are supplied
to summary generation for action-item ownership. If either source track is
missing or silent, the recording falls back to the existing single-audio
transcription path. Imported audio files also keep the single-audio path.
