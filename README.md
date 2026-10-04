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

### Menu bar recording

The menu bar shows **Recording**, **Paused**, **Stopped**, **Preparing**, **Saving**
or **Error**, together with active elapsed time (pauses are excluded). Open it to
start, pause, resume or stop capture, add a timestamped note, inspect errors and
warnings, retry unsaved notes, or reopen the main window. Both surfaces use one
application-owned recorder and the same notes sidecar; they cannot start separate
recordings. The current source and microphone choices apply to menu bar starts.

Closing the main window leaves the app and recording running. **Quit meet-log**
(including the standard app menu / Command-Q) asks for confirmation during capture,
startup, saving, or when notes are unsaved. **Cancel** keeps the session running;
**Save and Quit** waits for pending startup / controls / finalization, stops capture,
and saves notes. A stop or notes-save failure cancels that quit request and shows
an error so the recording can be checked. Mixdown failure preserves source tracks
and does not prevent quitting once notes are saved. Idle / already-saved sessions
quit directly. Force Quit and crashes use the interrupted-recording recovery flow.

The panel uses standard macOS buttons and text fields. Use Tab / Shift-Tab with
macOS keyboard navigation enabled, Return to add a note, and Escape to dismiss the
panel. While the panel is active, Command-R starts, Command-P pauses/resumes,
Command-period stops and Command-O opens the main window. Controls have text
labels and accessible state / elapsed-time labels for VoiceOver. These shortcuts
are local to the app; no global hotkeys are installed.

`MenuBarRecordingTests` covers shared-session command serialization, note timestamps
and persistence, closed-window lifetime, cancelled / idle quit, quit during startup
or saving, paused / input-test quit, and saving failures. Real-Mac verification is
pending: operate from another app, close and reopen the main window during capture,
check the menu bar timer and paused notes, cancel then confirm quit, induce a
permission / destination error, and check keyboard navigation and VoiceOver.

### Timestamped notes

While recording or paused, enter a note and choose **Add** (or press Return).
The timestamp uses active recording time, excluding pauses. Notes appear in
chronological order in the recording result and Library details, where they can
be added, edited, or deleted. For saved recordings, enter the position in seconds.

Notes are saved atomically as `<recording>_notes.json` beside the audio tracks
after each live note is added and retried when recording completes, including when mixdown fails. A missing sidecar means
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

### Timestamp playback

Library details and imported-audio results include a shared playback panel. Select
an utterance, saved note, or screen OCR timestamp to jump and play. The slider
seeks without changing the paused/playing state; the speed selector supports
0.5×–2×. At the end, Play restarts from zero. A timestamp beyond the end stops at
the end; invalid timestamps are ignored.

Audio and screen video use one AVPlayer composition and clock. Recorded timestamps
are preserved, including leading gaps; capture has already removed paused time.
When no mix exists, available source audio tracks play together. Audio-only,
screen-only, missing and unreadable media are identified in the playback panel.
Switching recordings or leaving the screen stops and releases the old media.
Legacy transcripts without segment timestamps remain readable with manual seek.

`PlaybackTests` covers seek boundaries, speed, missing files, stale loads, source
track overlap and synthetic audio/video time ranges. Physical-device validation
is still required: record audible/visible markers before and after at least two
pause/resume cycles, then check utterance/note/OCR jumps, slider seeking and
0.5×/1×/2× playback against those markers. Record the Mac/macOS version and observed
sync offset at the start, after each resume and at the end. Synthetic tests do not
establish capture synchronization on a real Mac.

### Recording input test and health warnings

Before a meeting, choose the audio sources and microphone, then select **Test
Inputs (5 seconds)**. Speak and play system audio; the test stops automatically
and offers separate System audio / Microphone playback. Use headphones to avoid
feedback. Test recordings contain audio only, live in a unique temporary folder,
do not enter the Library or notes workflow, and are removed at the next test or
recording (or normal recorder teardown). A crash may leave temporary files for
macOS to clean up. Test playback confirms only the selected inputs at that time.

During recording, each enabled audio source is monitored independently:

- **Silence:** RMS below 0.001 (-60 dBFS) for 30 seconds while buffers continue.
- **Audio interruption:** no nonempty, metered audio buffer for 5 seconds,
  including when the source has never supplied a buffer. This takes precedence
  over silence. A resumed stream starts a fresh silence window.
- **Microphone disconnection/default-device change:** reported through the device
  inventory stream; select a working input and verify the levels.
- Audio monitoring is suspended during pause, restarts with a fresh grace period
  on resume/input switch, and ignores disabled sources. Silence and interruptions
  never stop recording automatically.

Warnings appear in the recorder panel and sound the macOS alert. They stay until
dismissed (they are warning history, not live status indicators). The same warning
for the same source is sounded at most once every 60 seconds, including after
dismissal, recovery, or pause/resume. No Notification Center permission is needed;
there are no background notification banners if the panel is hidden.

Free space is checked on the selected destination before capture, then every
10 seconds while recording **or paused**. The checked destination stays pinned
throughout the session, even if Settings changes. Audio-only recording warns at
512 MiB; screen recording warns at 2 GiB. At **256 MiB or less**, startup is blocked
or an active recording stops, closes its source tracks/video, and skips mixdown
to reserve space. Existing source playback and notes saving remain available.
An unreadable capacity blocks startup; during recording it warns without stopping.
Checks use currently free filesystem bytes, conservatively excluding purgeable
space. Another process can consume space between checks, so the reserve cannot
guarantee successful finalization under every disk-full/unplugged-volume condition.

`RecordingHealthTests` controls time, storage capacity and recorder events;
recorder orchestration tests verify emergency finalization without mixdown.
**Physical-device validation is pending**: this change was prepared on Linux,
without a Mac or USB/Bluetooth audio devices. Before closing #45, record the
Mac/macOS/device versions and results for USB/Bluetooth input tests, live unplug
and re-selection, 30-second silence, 5-second buffer loss, pause/resume, warning
cooldown, and audio/screen recordings on a test volume reaching both capacity
thresholds. Verify the saved tracks/video and notes can still be reopened.

### Interrupted recording recovery

A new recording writes `session.json` before capture begins. The active elapsed
clock is checkpointed atomically every second and on pause/resume/finalization.
Live notes are atomically saved after each addition. A separate completion marker
is written only after normal finalization and pending notes have been saved.
Input tests stay in their existing temporary directory and are not offered for
recovery.

Each audio source also writes independently finalized AAC backups approximately
every **5 seconds** (plus one capture buffer) to `<track>.segments`. Only closed,
renamed segments are used; `.partial.m4a` files remain untouched. The main M4A may
be unreadable before close, so a successful normal recording does not establish
crash recoverability. Backups roughly double AAC encoding work/audio storage
(about 58 MB/hour per source in addition to the original, plus container overhead).
They are retained with the recording. Screen MP4 uses 10-second movie fragments,
following Apple's [movieFragmentInterval documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval).
The interval is a target, not a guaranteed bound on data loss.

At launch, interrupted sessions in the default, current and previously bookmarked
recording destinations are offered for recovery. Unavailable destinations report
an error without blocking scans of accessible folders. The recorder's recovery
button reopens the launch results. Restore the original destination in Settings
if a drive was disconnected. Recovered recordings from earlier destinations also
appear in Library while those destinations remain accessible.

The recovery screen lists checkpoint age/state, readable media ranges, missing
segments and saved note count. Recovery exports into a hidden staging folder,
then atomically publishes a single `recovered` folder and report. Only published
results enter Library; repeated recovery returns that result without overwriting
later edits. Originals, unreadable media, corrupt notes and unfinished backup
files are never deleted. Gaps between audio backup segments retain their timeline
positions. Mixdown failures still register the recovered source tracks for a
Library retry; notes-only recovery is supported. The recovery report remains
visible in Library. If nothing is readable, no result is published.

The last checkpoint can lag capture time, and uncommitted audio/video tails,
unsaved notes and capture-time dropouts cannot be reconstructed. Media inspection
checks container metadata; export failures are reported separately, with audio
falling back to its closed segments. There is no guarantee of recovery after
power loss, disk failure, or exhausted storage.

`RecordingRecoveryTests`, `RecordingJournalTests` and `RecordingNotesTests` cover
state restoration, live note persistence, corrupt/missing media, partial tails,
timeline gaps, source preservation, notes-only publication and idempotent retries.
**Physical-device force-quit validation is pending** (development environment:
Linux, no macOS/Xcode or capture devices). Before closing #46, record Mac/macOS,
input devices, elapsed time and results for the following matrix:

- Force quit during the first 5 seconds, after multiple intervals, while paused,
  after resuming, and during normal finalization/mixdown.
- Test system-only, microphone-only, both sources, and audio with screen MP4.
  Add notes before/after each pause; compare recovered timestamps to audible and
  visible markers. Check the last readable M4A segment and MP4 fragment.
- Repeat recovery and force quit during recovery; confirm one Library item and
  unchanged original hashes. Edit recovered notes, then retry and verify edits.
- Disconnect/reconnect a custom destination, change destinations during recording,
  and simulate disk-full on a disposable test volume. Confirm errors, preserved
  originals and available recovery candidates after restarting.

No physical force-quit results are claimed by the synthetic tests.

### Library の会議名・タグ・ゴミ箱操作

- 「会議名・タグを編集」で表示名とカンマ区切りのタグを保存できます。保存先は `<元の保存名>_library.json` で、音声・動画のファイル名や既存 sidecar の関連付けは変更しません。
- 検索欄で会議名・タグ・保存済みテキストを検索し、タグの選択で一覧を絞り込めます。
- 「ゴミ箱へ移動」から「画面動画のみ」または「録音一式」を選択します。確認画面に実際の対象ファイル・保存場所・合計容量を表示します。
- 動画のみの場合は音声・議事録・メモ・保存済み OCR を残します。動画削除後も会議は Library に残り、動画再生・再 OCR が利用できないことを表示します。
- 一式の場合は関連する音声・動画・テキスト・表示情報と録音復旧用の音声断片を対象にします。復旧済み会議は、セッション ID と保存名が一致した元セッションの素材も確認画面に含みます。チェックポイント・ロック・復旧結果の管理ファイルは、復旧の再提示を防ぐため残します。
- 別の会議や無関係なファイルを含むフォルダ全体は削除しません。録音中のセッションロック、複数ウィンドウでの処理・編集中・再生中、キャンセル済み処理の終了待ちを確認します。部分失敗はファイルごとに報告し、残った会議を再確認できます。
