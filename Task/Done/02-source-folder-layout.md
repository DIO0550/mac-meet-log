# Task 02: Source Folder Layout

## Goal

アプリ層と core 層の責務が見えるように、ファイル配置を整理する。

## Steps

- app 側に `App/`, `Features/Recorder/`, `Support/` を作る
- core 側に `Sources/Session`, `Sources/Capture`, `Sources/FileIO` を作る
- 既存の `meet_logApp.swift` を `App/` 相当の場所へ移す
- 既存の `ContentView.swift` は後続の `RecorderView` へ置き換えやすい場所へ移す、または削除予定として扱う

## Acceptance Criteria

- [ ] app 層の Swift files が `meet-log/meet-log/` 以下で整理されている
- [ ] core 層の Swift files が `DualTrackRecorder/Sources/` 以下で整理されている
- [ ] core target の source に SwiftUI import がない
- [ ] 移動後も app target が build できる

## Notes

- workspace は作らない
- target の物理フォルダと Xcode group のズレを最小化する
