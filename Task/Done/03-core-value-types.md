# Task 03: Core Value Types

## Goal

`DualTrackRecorder` の public API で使う値型を先に定義する。

## Files

- `RecorderConfiguration.swift`
- `RecordingSources.swift`
- `RecordingResult.swift`
- `RecorderError.swift`
- `RecorderEvent.swift`
- `RecorderState.swift`

## Acceptance Criteria

- [ ] `RecordingSources` が system audio / microphone の有効無効を表現できる
- [ ] 両方 off を validation error として扱える
- [ ] `RecordingResult` が duration、track URL、mixdown URL、display file name を持つ
- [ ] `RecorderError` が permission / capture / output / invalid state / mixdown を区別できる
- [ ] public にする型が `Sendable` を意識している

## Tests

- [ ] `RecordingSources` の validation
- [ ] `RecorderError` の user-facing message 変換が必要なら別 task に送る
