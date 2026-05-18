# Task 11: System Audio Tap

## Goal

Core Audio Process Tap を使ってシステム音声を取得する component を実装する。

## Steps

- `SystemAudioTap` を追加する
- `CATapDescription` と `AudioHardwareCreateProcessTap` の利用箇所を隔離する
- tap lifecycle を start / stop に閉じ込める
- writer と meter に buffer を渡す

## Acceptance Criteria

- [ ] system audio source on の時だけ Process Tap を作成する
- [ ] system audio source off の時は Process Tap を作成しない
- [ ] tap 作成失敗が `RecorderError.captureFailed` になる
- [ ] stop 時に tap を破棄する
- [ ] UI 層に CoreAudio 型が漏れない

## Manual Checks

- [ ] macOS 14.2+ 実機で tap を作成できる
- [ ] entitlement / runtime 要件を確認する
