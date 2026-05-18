# Task 14: Recorder View Model

## Goal

SwiftUI から扱いやすい UI state と command を提供する。

## Steps

- `RecorderViewModel` を追加する
- `DualTrackRecorder.events` を購読する
- UI state に state、elapsed、sources、level、waveform、completion を持たせる
- start / pause / resume / stop / dismiss を command として公開する

## Acceptance Criteria

- [ ] UI が core actor を直接細かく扱わずに済む
- [ ] 録音中に elapsed が更新される
- [ ] 保存完了 result が UI state に残る
- [ ] dismiss または次回 start まで completion が残る
- [ ] error state が UI 表示可能な値に変換される

## Tests

- [ ] fake recorder による state mapping
- [ ] completion persistence
