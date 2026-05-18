# Task 10: Microphone Capture

## Goal

AVAudioEngine を使ってマイク入力を取得する component を実装する。

## Steps

- `MicrophoneCapture` を追加する
- マイク権限の状態を確認する
- input node から buffer を取得する
- writer と meter に buffer を渡す

## Acceptance Criteria

- [ ] マイク source on の時だけ AVAudioEngine が起動する
- [ ] マイク source off の時は権限要求も起動も行わない
- [ ] 権限拒否が `RecorderError.permissionDenied` になる
- [ ] capture failure が `RecorderError.captureFailed` になる
- [ ] stop 時に engine が停止する

## Manual Checks

- [ ] 初回起動で TCC prompt が出る
- [ ] 権限拒否後にクラッシュしない
