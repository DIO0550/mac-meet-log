# Task 06: Fake Session Tests

## Goal

実 audio capture なしで public API と状態遷移を検証できる test harness を作る。

## Steps

- fake capture component を追加する
- fake writer / fake mixdown を追加する
- `DualTrackRecorderTests` に基本状態遷移テストを追加する

## Acceptance Criteria

- [ ] capture 未実装でも core API の test が通る
- [ ] `start -> stop` の complete result を検証できる
- [ ] `start -> pause -> resume -> stop` を検証できる
- [ ] capture failure を failed state として検証できる

## Out Of Scope

- 実マイク録音
- 実 Process Tap
- 実ファイル書き込み
