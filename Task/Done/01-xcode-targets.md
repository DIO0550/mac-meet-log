# Task 01: Xcode Targets

## Goal

既存の `meet-log.xcodeproj` に `DualTrackRecorder` framework target と test target を追加する。

## Steps

- `DualTrackRecorder` framework target を作成する
- `DualTrackRecorderTests` unit test target を作成する
- `meet-log` app target から `DualTrackRecorder` を link / embed する
- scheme で app と framework の build が通る状態にする

## Acceptance Criteria

- [ ] `meet-log` app target が build できる
- [ ] `DualTrackRecorder` framework target が build できる
- [ ] `DualTrackRecorderTests` target が test 実行対象に入っている
- [ ] app 側で `import DualTrackRecorder` が解決できる

## Out Of Scope

- public API の詳細実装
- UI の作り込み
