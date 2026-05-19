# Task 23: Switch Microphone While Recording

## Goal

録音中にマイク入力デバイスを変更し、録音セッションを止めずに新しい入力へ切り替える。

## Steps

- `DualTrackRecorder` に `switchMicrophoneInput` 相当の public API を追加する
- `ActiveCaptureSession` で microphone capture のみ差し替えられるようにする
- 切り替え中も既存の microphone track writer を継続利用する
- 切り替え成功 / 失敗を `RecorderEvent` として UI へ通知する
- system audio capture と session clock は切り替え中も維持する

## Acceptance Criteria

- [ ] recording 中に microphone device を変更できる
- [ ] 切り替え時に録音状態が idle / finalizing へ戻らない
- [ ] system audio track は途切れず継続する
- [ ] 切り替え失敗時は録音全体を落とさず、元のマイクまたは明確なエラー状態を維持する
- [ ] microphone off の状態では切り替え API が no-op または typed error になる

## Tests

- [ ] fake capture で microphone のみ差し替わる
- [ ] switch failure 時の状態維持
- [ ] recording / paused / finalizing 各状態での API availability
